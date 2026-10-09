import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonRegistration")

/// Registers `Canopy --daemon` as this user's LaunchAgent. Keyed by bundle
/// id so a Debug build registers its own agent and never replaces Release's.
enum DaemonRegistration {
    static func plistName(bundleId: String) -> String { "\(bundleId).daemon.plist" }
    /// The launchd label: `Label` in the plist, which `plistName` names after.
    static func label(bundleId: String) -> String { "\(bundleId).daemon" }

    /// Release registers at every launch. A Debug build registers only when
    /// asked: every Debug launch would otherwise install a login item pointing
    /// at whichever worktree's build ran first, and it would keep running
    /// from there after that worktree is gone.
    static func shouldRegister(isDebugBuild: Bool, environment: [String: String]) -> Bool {
        !isDebugBuild || environment["CANOPY_REGISTER_DAEMON"] == "1"
    }

    static func status() -> SMAppService.Status { service.status }

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistName(bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"))
    }

    /// Called at every GUI launch; idempotent. See `shouldRegister`.
    @MainActor
    static func ensureRegistered() {
        #if DEBUG
        let isDebugBuild = true
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { return }
        #else
        let isDebugBuild = false
        #endif
        guard shouldRegister(isDebugBuild: isDebugBuild, environment: ProcessInfo.processInfo.environment) else { return }
        let service = self.service
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            logger.notice("daemon agent needs approval in System Settings › Login Items")
        default:
            do {
                try service.register()
                logger.notice("daemon agent registered (status \(service.status.rawValue))")
            } catch {
                logger.error("daemon agent register failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `Canopy --unregister-daemon`: removes this build's agent and exits.
    /// The only clean way to undo `register()` — `launchctl bootout` stops the
    /// job but leaves the Login Items record, which re-arms it at next login.
    static func unregisterAndExit() -> Never {
        do {
            try service.unregister()
            print("daemon agent unregistered")
            // No daemon will run to re-enable lid-close sleep, which a stop leaves disabled.
            MainActor.assumeIsolated {
                if SleepGuardPolicy.mayRestoreClamshellSleep(lidClosed: ClamshellSleep.lidClosed(),
                                                             litDisplays: ClamshellSleep.litDisplayCount()) {
                    ClamshellSleep.setDisabled(false)
                } else {
                    print("lid-close sleep may still be disabled; open the lid and run this again to reset it")
                }
            }
            exit(0)
        } catch {
            print("daemon agent unregister failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
