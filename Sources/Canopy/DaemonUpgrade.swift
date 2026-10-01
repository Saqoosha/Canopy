import Foundation

/// A daemon outlives the app update that replaced its binary: launchd keeps the
/// old process until it exits. The daemon notices the new build on disk and
/// restarts itself (exit non-zero, so launchd's KeepAlive starts the new one)
/// once no session is in the middle of anything.
enum DaemonUpgrade {
    /// The build the running process was launched from, read once.
    static let launchedBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    /// The build now on disk, read fresh; `Bundle.main` caches the launch-time Info.plist.
    static func onDiskBuild(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    /// Restart only for a readable, different build that was already on disk at the previous
    /// check (a non-atomic copy can land Info.plist before the executable), only under launchd
    /// (nothing else would start the new build), and never while a session would lose
    /// something (`ShimProcess.upgradeBlocker`).
    static func shouldRestart(launchedBuild: String?, onDiskBuild: String?, previousOnDiskBuild: String?,
                              underLaunchd: Bool, blocked: Bool) -> Bool {
        guard let launchedBuild, let onDiskBuild, launchedBuild != onDiskBuild,
              previousOnDiskBuild == onDiskBuild else { return false }
        return underLaunchd && !blocked
    }

    /// launchd names a job's process with its label in `XPC_SERVICE_NAME`.
    static func isUnderLaunchd(env: [String: String], bundleId: String) -> Bool {
        env["XPC_SERVICE_NAME"] == DaemonRegistration.label(bundleId: bundleId)
    }

    /// The frame a daemon sends each attached client just before it restarts for an upgrade.
    static let restartingFrameType = "daemon_restarting"

    /// Why `restart_now` must not exit, or nil. Without launchd nothing would start the new build.
    static func restartNowRefusal(pendingBuild: String?, underLaunchd: Bool) -> String? {
        guard pendingBuild != nil else { return "no update is waiting" }
        guard underLaunchd else { return "the session service was not started by launchd, so nothing would start the new build" }
        return nil
    }

    /// The frame type control subscribers receive.
    static let stateFrameType = "upgrade_state"
}

/// One session holding a daemon upgrade, and why (`ShimProcess.upgradeBlocker`).
struct UpgradeHold: Equatable {
    let key: String  // OpenSession.id, as `session_state` keys rows
    let title: String
    let reason: String
}

/// A live shim still on an older extension than the one installed.
struct StaleExtensionSession: Equatable {
    let key: String
    let title: String
    let running: String
    /// Why restarting it now would lose something, or nil.
    let blocker: String?
}

struct ExtensionUpgradeState: Equatable {
    let installed: String
    let stale: [StaleExtensionSession]
}

/// What the daemon tells the GUI about updates it has not applied yet.
struct UpgradeState: Equatable {
    var runningBuild: String
    var pendingBuild: String?
    var heldBy: [UpgradeHold]
    var notUnderLaunchd: Bool
    var extensionState: ExtensionUpgradeState?

    var isEmpty: Bool { pendingBuild == nil && (extensionState?.stale.isEmpty ?? true) }

    var wire: [String: Any] {
        var dict: [String: Any] = [
            "runningBuild": runningBuild,
            "heldBy": heldBy.map { ["key": $0.key, "title": $0.title, "reason": $0.reason] },
            "notUnderLaunchd": notUnderLaunchd,
        ]
        if let pendingBuild { dict["pendingBuild"] = pendingBuild }
        if let extensionState {
            let stale = extensionState.stale.map { row -> [String: Any] in
                var r: [String: Any] = ["key": row.key, "title": row.title, "running": row.running]
                if let blocker = row.blocker { r["blocker"] = blocker }
                return r
            }
            dict["extension"] = ["installed": extensionState.installed, "stale": stale] as [String: Any]
        }
        return dict
    }

    init(runningBuild: String, pendingBuild: String?, heldBy: [UpgradeHold], notUnderLaunchd: Bool,
         extensionState: ExtensionUpgradeState?) {
        self.runningBuild = runningBuild
        self.pendingBuild = pendingBuild
        self.heldBy = heldBy
        self.notUnderLaunchd = notUnderLaunchd
        self.extensionState = extensionState
    }

    init?(wire: [String: Any]) {
        guard let running = wire["runningBuild"] as? String,
              let holds = wire["heldBy"] as? [[String: Any]] else { return nil }
        var parsedHolds: [UpgradeHold] = []
        for h in holds {
            guard let key = h["key"] as? String, let title = h["title"] as? String,
                  let reason = h["reason"] as? String else { return nil }
            parsedHolds.append(UpgradeHold(key: key, title: title, reason: reason))
        }
        var ext: ExtensionUpgradeState?
        if let e = wire["extension"] as? [String: Any] {
            guard let installed = e["installed"] as? String, let rows = e["stale"] as? [[String: Any]] else { return nil }
            var stale: [StaleExtensionSession] = []
            for r in rows {
                guard let key = r["key"] as? String, let title = r["title"] as? String,
                      let runningVersion = r["running"] as? String else { return nil }
                stale.append(StaleExtensionSession(key: key, title: title, running: runningVersion,
                                                   blocker: r["blocker"] as? String))
            }
            ext = ExtensionUpgradeState(installed: installed, stale: stale)
        }
        self.init(runningBuild: running, pendingBuild: wire["pendingBuild"] as? String, heldBy: parsedHolds,
                  notUnderLaunchd: wire["notUnderLaunchd"] as? Bool ?? false, extensionState: ext)
    }
}
