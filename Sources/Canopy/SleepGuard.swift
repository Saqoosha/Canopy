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

    init(sessions: @escaping () -> [OpenSession]) {
        self.sessions = sessions
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
                                               workingSessions: working, battery: BatteryReading.current())
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

/// The internal battery's state, or nil on a Mac without one.
struct BatteryReading: Equatable {
    var onBattery: Bool
    var percent: Int

    static func current() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return BatteryReading(onBattery: state == kIOPSBatteryPowerValue, percent: current * 100 / max)
        }
        return nil
    }
}

/// The hold decision, pure so the probe can reach it.
enum SleepGuardPolicy {
    /// Below this, on battery, the Mac is allowed to sleep even with work running:
    /// a sleeping Mac resumes the turn later, a dead one loses it.
    static let batteryFloorPercent = 20

    /// `battery` is read only once a session is busy: it is an IOKit query, and the idle case is every tick.
    static func decide(enabled: Bool, workingSessions: Int, battery: @autoclosure () -> BatteryReading?) -> (hold: Bool, reason: String) {
        guard enabled else { return (false, "turned off in Settings") }
        guard workingSessions > 0 else { return (false, "no session is busy") }
        if let battery = battery(), battery.onBattery, battery.percent < batteryFloorPercent {
            return (false, "on battery below \(batteryFloorPercent)%")
        }
        return (true, "a session is busy")
    }
}
