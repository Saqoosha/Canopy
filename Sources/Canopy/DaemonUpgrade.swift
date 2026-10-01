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
}
