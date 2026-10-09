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
    /// Read once: whether `AppleClamshellState` exists. A lid-less Mac has nothing to disable.
    private var hasLid = false
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
        hasLid = controlsClamshell && ClamshellSleep.lidClosed() != nil
        // A previous daemon that stopped or died while holding may have left the flag set.
        clamshellMayBeDisabled = hasLid
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
        releaseAssertions()
        // A notice in flight cannot hold this up: nothing will run once the process exits.
        releaseNoticeInFlight = false
        // Only with the lid open: a stop is usually a restart, and turning lid-close sleep back
        // on with the lid closed sleeps the Mac before the next daemon can hold it again.
        if ClamshellSleep.lidClosed() == false { restoreClamshellSleepIfHarmless() }
    }

    private func tick() {
        let open = sessions()
        let working = open.filter { $0.shim?.holdsSystemAwake == true }.count
        let settings = CanopySettings.shared
        // Read at most once per tick, so the decision and the battery alert see one charge.
        var powerRead: PowerSource?
        func power() -> PowerSource {
            if let read = powerRead { return read }
            let read = PowerSource.current()
            powerRead = read
            return read
        }
        let decision = SleepGuardPolicy.decide(enabled: settings.preventSleepWhileWorking, workingSessions: working,
                                               stayReachable: controlsClamshell && settings.stayReachableRemotely,
                                               openSessions: open.count,
                                               batteryFloor: settings.sleepBatteryFloorPercent,
                                               power: power())
        // Before `release()`: a release notice must leave before lid-close sleep is re-enabled.
        if hasLid, decision.hold || batteryAlerts.isWatching {
            updateBatteryAlerts(decision: decision, power: power(), floor: settings.sleepBatteryFloorPercent)
        }
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

    private var batteryAlerts = BatteryAlertTracker()
    /// A "going to sleep" notice is on its way: re-enabling lid-close sleep now would sleep the
    /// Mac before it leaves, so the restore waits for the request to finish.
    private var releaseNoticeInFlight = false

    /// Tells the phone while a lid-closed Mac is held awake on battery: there is no screen to
    /// show it, and it may be in a bag (issue #346).
    private func updateBatteryAlerts(decision: SleepDecision, power: PowerSource, floor: Int) {
        guard case .battery(let onBattery, let percent) = power else {
            batteryAlerts.reset()
            return
        }
        let lidClosed = ClamshellSleep.lidClosed() == true
        // It sleeps only if lid-close sleep can be re-enabled now; with a display lit it stays up.
        let willSleep = !decision.hold && onBattery && lidClosed && ClamshellSleep.litDisplayCount() == 0
        guard let alert = batteryAlerts.update(watching: decision.hold && onBattery && lidClosed,
                                               sleepingNow: willSleep,
                                               percent: percent, belowFloor: decision.belowFloor,
                                               now: Date()) else { return }
        let settings = CanopySettings.shared
        let name = MachineIdentity.resolvedDisplayName(setting: settings.machineDisplayName,
                                                       fallback: MachineIdentity.defaultDisplayName())
        let message = alert.message(machine: name, reason: decision.reason, floor: floor)
        logger.notice("battery alert: \(message.body, privacy: .public)")
        guard case .released = alert else {
            RosterNotifier.postBattery(title: message.title, body: message.body)
            return
        }
        releaseNoticeInFlight = true
        RosterNotifier.postBattery(title: message.title, body: message.body) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.releaseNoticeInFlight = false
            self.tick()
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
                for held in [id, systemAssertion].compactMap({ $0 }) {
                    IOPMAssertionSetProperty(held, kIOPMAssertionDetailsKey as CFString, reason as CFString)
                }
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
    private var systemAssertionFailing = false

    /// Re-applied every tick while holding: another daemon (a Debug build) starting or
    /// releasing resets the shared flag, and so does powerd on a power-source change. The
    /// PreventSystemSleep assertion covers that change onto AC: the Mac drops to dark wake
    /// rather than sleep (measured). It has no effect on battery, and the opposite change
    /// (unplugging with the lid closed) still sleeps; only a root `pmset disablesleep` stops that.
    private func holdClamshell() {
        guard hasLid else { return }
        if systemAssertion == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventSystemSleep as CFString,
                                                            Self.assertionName as CFString, assertionReason as CFString?,
                                                            nil, nil, 0, nil, &id)
            if result == kIOReturnSuccess {
                systemAssertion = id
                systemAssertionFailing = false
            } else if !systemAssertionFailing {
                systemAssertionFailing = true
                logger.error("PreventSystemSleep assertion failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            }
        }
        ClamshellSleep.setDisabled(true)
        clamshellMayBeDisabled = true
        loggedClamshellDeferral = false
    }

    private func release() {
        releaseAssertions()
        restoreClamshellSleepIfHarmless()
    }

    private func releaseAssertions() {
        systemAssertionFailing = false
        if let id = systemAssertion {
            IOPMAssertionRelease(id)
            systemAssertion = nil
        }
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
        assertionReason = nil
    }

    private func restoreClamshellSleepIfHarmless() {
        guard hasLid, clamshellMayBeDisabled, !releaseNoticeInFlight else { return }
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

    /// `AppleClamshellState`, or nil when absent (no lid) or unreadable.
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

/// When to tell the phone about a lid-closed Mac held awake on battery: on entering that
/// state, at each 10% step below where it started, and once when it is let go to sleep there.
struct BatteryAlertTracker: Equatable {
    enum Alert: Equatable {
        case started(percent: Int)
        case dropped(percent: Int)
        case released(percent: Int, belowFloor: Bool)

        func message(machine: String, reason: String, floor: Int) -> (title: String, body: String) {
            switch self {
            case .started(let percent):
                return ("\(machine) is awake with the lid closed",
                        "On battery at \(percent)%: \(reason). It sleeps below \(floor)%.")
            case .dropped(let percent):
                return ("\(machine) battery \(percent)%",
                        "Still awake with the lid closed: \(reason). It sleeps below \(floor)%.")
            case .released(let percent, true):
                return ("\(machine) is going to sleep",
                        "Battery at \(percent)%, below \(floor)%. Canopy stopped keeping it awake.")
            case .released(let percent, false):
                return ("\(machine) is going to sleep",
                        "Battery at \(percent)%: \(reason), so Canopy stopped keeping it awake.")
            }
        }
    }

    /// A lid closed again within this of the last "awake" notice does not send another.
    static let restartCooldown: TimeInterval = 15 * 60

    /// The 10% step last reported, or nil while not watching.
    private(set) var lastStep: Int?
    private var lastStartedAt: Date?
    var isWatching: Bool { lastStep != nil }

    mutating func reset() { lastStep = nil }

    /// `sleepingNow`: the hold just ended with the lid closed on battery, so the Mac sleeps.
    mutating func update(watching: Bool, sleepingNow: Bool, percent: Int, belowFloor: Bool, now: Date) -> Alert? {
        if sleepingNow, isWatching {
            lastStep = nil
            // It really slept, so the next hold is news, not a lid flapping.
            lastStartedAt = nil
            return .released(percent: percent, belowFloor: belowFloor)
        }
        guard watching else {
            lastStep = nil
            return nil
        }
        let step = percent / 10 * 10
        guard let last = lastStep else {
            lastStep = step
            if let started = lastStartedAt, now.timeIntervalSince(started) < Self.restartCooldown { return nil }
            lastStartedAt = now
            return .started(percent: percent)
        }
        guard step < last else { return nil }
        lastStep = step
        return .dropped(percent: percent)
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
    /// `stayReachable`: hold with no busy session too, so the phone or another Mac can reach it,
    /// but only while a session is open: with none there is nothing to reach.
    static func decide(enabled: Bool, workingSessions: Int, stayReachable: Bool = false, openSessions: Int = 0,
                       batteryFloor: Int = defaultBatteryFloorPercent,
                       power: @autoclosure () -> PowerSource) -> SleepDecision {
        guard enabled else { return SleepDecision(hold: false, reason: "turned off in Settings") }
        guard workingSessions > 0 || (stayReachable && openSessions > 0) else {
            return SleepDecision(hold: false, reason: stayReachable ? "no session is open" : "no session is busy")
        }
        switch power() {
        case .unreadable:
            return SleepDecision(hold: false, reason: "battery state is unreadable")
        case .battery(onBattery: true, let percent) where percent < batteryFloor:
            return SleepDecision(hold: false, reason: "on battery below \(batteryFloor)%", belowFloor: true)
        case .battery, .noBattery:
            return SleepDecision(hold: true, reason: workingSessions > 0 ? "a session is busy" : "staying reachable remotely")
        }
    }
}

struct SleepDecision: Equatable {
    var hold: Bool
    var reason: String
    /// Released because the battery fell below the floor.
    var belowFloor = false
}
