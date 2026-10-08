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
    private var lastReason: String?

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
        if decision.reason != lastReason {
            lastReason = decision.reason
            logger.notice("\(decision.hold ? "holding" : "not holding", privacy: .public) idle sleep: \(decision.reason, privacy: .public)")
        }
        decision.hold ? acquire() : release()
    }

    private func acquire() {
        guard assertion == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Canopy: a Claude session is busy" as CFString, &id)
        guard result == kIOReturnSuccess else {
            logger.error("IOPMAssertionCreateWithName failed: \(result)")
            return
        }
        assertion = id
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

    static func decide(enabled: Bool, workingSessions: Int, battery: BatteryReading?) -> (hold: Bool, reason: String) {
        guard enabled else { return (false, "turned off in Settings") }
        guard workingSessions > 0 else { return (false, "no session is busy") }
        if let battery, battery.onBattery, battery.percent < batteryFloorPercent {
            return (false, "on battery at \(battery.percent)%, below \(batteryFloorPercent)%")
        }
        return (true, "\(workingSessions) session(s) busy")
    }
}
