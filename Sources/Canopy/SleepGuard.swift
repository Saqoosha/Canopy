import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SleepGuard")

/// Keeps the Mac from idle-sleeping while a session in this process is busy
/// (`ShimProcess.holdsSystemAwake`), so a long turn is not frozen mid-run and a
/// waiting question stays answerable from the phone. Wi-Fi stays associated as long
/// as the system is awake.
///
/// An idle-sleep assertion, the same as `caffeinate -i`: the display still sleeps,
/// and the assertion dies with the process, so a crash cannot leave the Mac unable
/// to sleep. It does NOT stop lid-close sleep on battery without an external display;
/// that needs the system-wide `pmset disablesleep`, which is root-only and outlives
/// the process.
///
/// Runs in every process that holds shims: the daemon for local sessions, the GUI
/// for the ones it still runs in-process. A daemon-hosted pane has no shim in the
/// GUI, so no session is counted twice.
@MainActor
final class SleepGuard {
    private let sessions: () -> [OpenSession]
    private var timer: Timer?
    private var assertion: IOPMAssertionID?
    private var lastLogged: String?
    private var acquireFailing = false
    private static var instances: [Weak] = []
    private struct Weak { weak var guardian: SleepGuard? }

    init(sessions: @escaping () -> [OpenSession]) {
        self.sessions = sessions
        Self.instances.append(Weak(guardian: self))
    }

    /// Re-decide now rather than at the next tick: a turn started from the phone does not
    /// reset the idle timer, so a Mac near its idle deadline could sleep before the tick.
    static func reevaluateAll() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                instances.removeAll { $0.guardian == nil }
                for entry in instances where entry.guardian?.timer != nil { entry.guardian?.tick() }
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        release()
    }

    private func tick() {
        let working = sessions().filter { $0.shim?.holdsSystemAwake == true }.count
        let decision = SleepGuardPolicy.decide(enabled: CanopySettings.shared.preventSleepWhileWorking,
                                               workingSessions: working, power: PowerSource.current())
        let held: Bool
        if decision.hold {
            held = acquire()
        } else {
            release()
            held = false
        }
        let line = "\(held ? "holding" : decision.hold ? "failed to hold" : "not holding") idle sleep: \(decision.reason)"
        if line != lastLogged {
            lastLogged = line
            logger.notice("\(line, privacy: .public)")
        }
    }

    private func acquire() -> Bool {
        guard assertion == nil else { return true }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Canopy: a Claude session is busy" as CFString, &id)
        guard result == kIOReturnSuccess else {
            if !acquireFailing { logger.error("IOPMAssertionCreateWithName failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)") }
            acquireFailing = true
            return false
        }
        acquireFailing = false
        assertion = id
        return true
    }

    private func release() {
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
    }
}

/// The internal battery, kept apart from a read that failed: treating a failure as
/// "no battery" would silently disable the floor on a laptop.
enum PowerSource: Equatable {
    case noBattery
    case battery(onBattery: Bool, percent: Int)
    case unreadable

    static func current() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .unreadable }
        return parse(list.map { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
    }

    /// One entry per power source; nil where its description could not be read.
    static func parse(_ descriptions: [[String: Any]?]) -> PowerSource {
        guard !descriptions.contains(where: { $0 == nil }) else { return .unreadable }
        guard let desc = descriptions.compactMap({ $0 }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType })
        else { return .noBattery }
        guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0,
              let state = desc[kIOPSPowerSourceStateKey] as? String else { return .unreadable }
        return .battery(onBattery: state == kIOPSBatteryPowerValue, percent: current * 100 / max)
    }
}

/// The hold decision, pure so the probe can reach it.
enum SleepGuardPolicy {
    /// Below this, on battery, the Mac is allowed to sleep even with work running:
    /// a sleeping Mac resumes the turn later, a dead one loses it.
    static let batteryFloorPercent = 20

    /// A turn or a waiting question holds only this long after the session's last activity
    /// (a turn starting, or any CLI frame). Bounds both a question left overnight and a
    /// working flag latched by a CLI that died under a live shim, which no frame clears.
    static let staleAfter: TimeInterval = 60 * 60

    /// Local background tasks are exempt: their completion is reconciled from the transcript,
    /// and a long one sends no frames while it runs. Remote ones are never passed in.
    static func sessionHolds(working: Bool, waitingOnHuman: Bool, reconcilableBackgroundTasks: Int,
                             sinceActivity: TimeInterval) -> Bool {
        if reconcilableBackgroundTasks > 0 { return true }
        return (working || waitingOnHuman) && sinceActivity < staleAfter
    }

    /// `power` is read only once a session is busy: it is an IOKit query, and the idle case is every tick.
    static func decide(enabled: Bool, workingSessions: Int, power: @autoclosure () -> PowerSource) -> (hold: Bool, reason: String) {
        guard enabled else { return (false, "turned off in Settings") }
        guard workingSessions > 0 else { return (false, "no session is busy") }
        switch power() {
        case .unreadable:
            return (false, "battery state is unreadable")
        case .battery(onBattery: true, let percent) where percent < batteryFloorPercent:
            return (false, "on battery below \(batteryFloorPercent)%")
        case .battery, .noBattery:
            return (true, "a session is busy")
        }
    }
}
