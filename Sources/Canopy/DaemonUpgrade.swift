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

    /// Restart only for a readable, different build, and never while a session is busy
    /// (`SessionReaper.isBusy`): stopping then would lose a turn, a question or a task.
    static func shouldRestart(launchedBuild: String?, onDiskBuild: String?, anyBusy: Bool) -> Bool {
        guard let launchedBuild, let onDiskBuild, launchedBuild != onDiskBuild else { return false }
        return !anyBusy
    }
}
