import CoreGraphics
import Foundation
import IOKit
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
/// to sleep. The assertion does not stop lid-close sleep with no external display;
/// the daemon's guard also disables that (`ClamshellSleep`), which is system-wide and
/// outlives the process. Re-enabling it with the lid closed blanks any lit display and
/// can sleep the Mac on the spot (measured), so it is re-enabled only once that is
/// harmless (`SleepGuardPolicy.mayRestoreClamshellSleep`), retried every tick.
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
    private let controlsClamshell: Bool
    /// The flag may be set: by this guard, or left by a daemon that died holding it.
    private var clamshellMayBeDisabled = false
    private var loggedClamshellDeferral = false
    /// The started guard; one per process.
    private static weak var active: SleepGuard?

    /// `controlsClamshell`: the daemon only. The flag is one per machine, and two
    /// processes setting it would undo each other.
    init(sessions: @escaping () -> [OpenSession], controlsClamshell: Bool = false) {
        self.sessions = sessions
        self.controlsClamshell = controlsClamshell
    }

    /// Re-decide now rather than at the next tick: a turn started from the phone does not
    /// reset the idle timer, so a Mac near its idle deadline could sleep before the tick.
    static func reevaluateActive() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { active?.tick() }
        }
    }

    func start() {
        guard timer == nil else { return }
        Self.active = self
        // A previous daemon that died while holding may have left the flag set.
        clamshellMayBeDisabled = controlsClamshell
        // `.common`, so a modal alert in the GUI does not freeze the release.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if Self.active === self { Self.active = nil }
        release()
    }

    private func tick() {
        let working = sessions().filter { $0.shim?.holdsSystemAwake == true }.count
        let settings = CanopySettings.shared
        let decision = SleepGuardPolicy.decide(enabled: settings.preventSleepWhileWorking, workingSessions: working,
                                               stayReachable: controlsClamshell && settings.stayReachableRemotely,
                                               batteryFloor: settings.sleepBatteryFloorPercent,
                                               power: PowerSource.current())
        let held: Bool
        if decision.hold {
            held = acquire(reason: decision.reason)
            if held { holdClamshell() }
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

    /// The assertion's name; `AwakeStatus` finds it by this, so Debug and Release do not see each other's.
    nonisolated static var assertionName: String {
        "Canopy (\(Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")): keeping the Mac awake"
    }

    private var assertionReason: String?

    /// `reason` rides on the assertion's Details, which `AwakeStatus` shows as the tooltip.
    private func acquire(reason: String) -> Bool {
        if let id = assertion {
            if reason != assertionReason {
                IOPMAssertionSetProperty(id, kIOPMAssertionDetailsKey as CFString, reason as CFString)
                assertionReason = reason
            }
            return true
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                        Self.assertionName as CFString, reason as CFString,
                                                        nil, nil, 0, nil, &id)
        guard result == kIOReturnSuccess else {
            if !acquireFailing { logger.error("IOPMAssertionCreateWithDescription failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)") }
            acquireFailing = true
            return false
        }
        acquireFailing = false
        assertion = id
        assertionReason = reason
        return true
    }

    private var systemAssertion: IOPMAssertionID?

    /// Re-applied every tick while holding: another daemon (a Debug build) starting or
    /// releasing resets the shared flag, and so does powerd on a power-source change. The
    /// PreventSystemSleep assertion covers that change onto AC: the Mac drops to dark wake
    /// rather than sleep (measured). It has no effect on battery, and the opposite change
    /// (unplugging with the lid closed) still sleeps; only a root `pmset disablesleep` stops that.
    private func holdClamshell() {
        guard controlsClamshell else { return }
        if systemAssertion == nil {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventSystemSleep as CFString,
                                                  Self.assertionName as CFString, assertionReason as CFString?,
                                                  nil, nil, 0, nil, &id) == kIOReturnSuccess {
                systemAssertion = id
            }
        }
        ClamshellSleep.setDisabled(true)
        clamshellMayBeDisabled = true
        loggedClamshellDeferral = false
    }

    private func release() {
        if let id = systemAssertion {
            IOPMAssertionRelease(id)
            systemAssertion = nil
        }
        restoreClamshellSleepIfHarmless()
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
        assertionReason = nil
    }

    private func restoreClamshellSleepIfHarmless() {
        guard controlsClamshell, clamshellMayBeDisabled else { return }
        let lidClosed = ClamshellSleep.lidClosed()
        let lit = ClamshellSleep.litDisplayCount()
        guard SleepGuardPolicy.mayRestoreClamshellSleep(lidClosed: lidClosed, litDisplays: lit) else {
            if !loggedClamshellDeferral {
                loggedClamshellDeferral = true
                logger.notice("lid-close sleep stays disabled until the lid opens or no display is lit (lid closed: \(String(describing: lidClosed), privacy: .public), lit: \(String(describing: lit), privacy: .public))")
            }
            return
        }
        if ClamshellSleep.setDisabled(false) {
            clamshellMayBeDisabled = false
            logger.notice("lid-close sleep re-enabled")
        }
    }
}

/// The kernel's lid-close sleep switch (`IOPMrootDomain`'s `kPMSetClamshellSleepState`,
/// the call Amphetamine uses). Needs no root, but is machine-wide and is not reset when
/// the caller dies.
@MainActor
enum ClamshellSleep {
    private static var lastFailure: kern_return_t?

    @discardableResult
    static func setDisabled(_ disabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        var result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == KERN_SUCCESS {
            var input: [UInt64] = [disabled ? 1 : 0]
            var outputCount: UInt32 = 0
            result = IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, &outputCount)
            IOServiceClose(connection)
        }
        if result != KERN_SUCCESS, result != lastFailure {
            logger.error("clamshell sleep \(disabled ? "disable" : "enable", privacy: .public) failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
        }
        lastFailure = result == KERN_SUCCESS ? nil : result
        return result == KERN_SUCCESS
    }

    /// `AppleClamshellState`, or nil when it cannot be read.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// Displays currently drawing, or nil when CoreGraphics will not say.
    static func litDisplayCount() -> Int? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        return Int(count)
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

    /// One entry per power source; nil where its description could not be read, which may
    /// be the battery itself, so it is unreadable only when no readable entry is the battery.
    static func parse(_ descriptions: [[String: Any]?]) -> PowerSource {
        guard let desc = descriptions.compactMap({ $0 }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType })
        else { return descriptions.contains { $0 == nil } ? .unreadable : .noBattery }
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
    static let defaultBatteryFloorPercent = 20
    static let batteryFloorRange = 5...95

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

    /// Re-enabling lid-close sleep with the lid closed blanks a lit display and may sleep the
    /// Mac, so only when the lid is open or nothing is lit. An unreadable input counts as unsafe.
    static func mayRestoreClamshellSleep(lidClosed: Bool?, litDisplays: Int?) -> Bool {
        lidClosed == false || litDisplays == 0
    }

    /// `power` is read only once a session is busy: it is an IOKit query, and the idle case is every tick.
    /// `stayReachable`: hold with no busy session too, so the phone or another Mac can reach it at any time.
    static func decide(enabled: Bool, workingSessions: Int, stayReachable: Bool = false,
                       batteryFloor: Int = defaultBatteryFloorPercent,
                       power: @autoclosure () -> PowerSource) -> (hold: Bool, reason: String) {
        guard enabled else { return (false, "turned off in Settings") }
        guard workingSessions > 0 || stayReachable else { return (false, "no session is busy") }
        switch power() {
        case .unreadable:
            return (false, "battery state is unreadable")
        case .battery(onBattery: true, let percent) where percent < batteryFloor:
            return (false, "on battery below \(batteryFloor)%")
        case .battery, .noBattery:
            return (true, workingSessions > 0 ? "a session is busy" : "staying reachable remotely")
        }
    }
}
