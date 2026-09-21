import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "OpenRedirect")

/// Host-side half of `canopy-remote-open.sh`: puts the redirector on a
/// session's PATH, and tells it where the person watching actually is.
///
/// The address lives in a FILE rather than in the session's environment
/// because a mirror attaches and detaches while the CLI runs, and an
/// environment variable cannot be revoked after spawn — the same limit
/// `ShimProcess`'s `CANOPY_PANE` records. The script reads the file at the
/// moment `open` is called, so it follows the mirror rather than a snapshot
/// of it.
///
/// Nothing here is reached for a session nobody is watching from elsewhere:
/// no file, and the script is then exactly the stock `open`.
enum OpenRedirect {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".canopy")
    }
    static var binDirectory: URL { root.appendingPathComponent("bin") }
    static var viewersDirectory: URL { root.appendingPathComponent("viewers") }

    /// What may be written as a destination, and it is deliberately the same
    /// shape the script itself re-checks. A host is handed to `ssh` and to
    /// `scp` as an argument, so anything that could read as a flag or split
    /// into two words is refused rather than escaped. No colon either: scp
    /// splits its target on it, which is why an IPv6 peer is declined.
    static func sanitizedHost(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.hasPrefix("-"), raw.count <= 255
        else { return nil }
        let allowed = CharacterSet(charactersIn: "-._%@")
            .union(.alphanumerics)
        return raw.unicodeScalars.allSatisfy(allowed.contains) ? raw : nil
    }

    /// Copies the bundled script to `~/.canopy/bin/open` (plus an `xdg-open`
    /// alias) and answers the directory to prepend to PATH, or nil if the
    /// copy failed — in which case the session simply keeps the stock `open`.
    ///
    /// Done per spawn rather than once at launch so the file always matches
    /// the running build, and so a Canopy that opens no session writes
    /// nothing. It is a 3.5 KB copy.
    @discardableResult
    static func installScript() -> URL? {
        guard let source = scriptSource() else {
            logger.error("no canopy-remote-open.sh in the bundle or the source tree")
            return nil
        }
        let destination = binDirectory.appendingPathComponent("open")
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let body = try Data(contentsOf: URL(fileURLWithPath: source))
            try body.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let alias = binDirectory.appendingPathComponent("xdg-open")
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
            return binDirectory
        } catch {
            logger.error("install failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Names `host` as where this session's `open` should land.
    static func publish(key: String, host: String) {
        guard let host = sanitizedHost(host), !key.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: viewersDirectory, withIntermediateDirectories: true)
            try Data(host.utf8).write(to: viewersDirectory.appendingPathComponent(key), options: .atomic)
            logger.notice("open redirected to a watching Mac")
        } catch {
            logger.error("publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens `path` where `key`'s watcher is, by running the installed script
    /// exactly as an agent's `open` would — so a click in a mirror pane and an
    /// agent's `open` share one path, one set of guards and one fallback.
    /// Fire-and-forget: the script already falls back to opening here.
    static func openOnViewer(path: String, key: String) {
        let script = binDirectory.appendingPathComponent("open")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            logger.error("openOnViewer: script missing; opening here instead")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let proc = Process()
        proc.executableURL = script
        proc.arguments = [path]
        var env = ProcessInfo.processInfo.environment
        env["CANOPY_OPEN_KEY"] = key
        env["PATH"] = "\(binDirectory.path):" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            if p.terminationStatus != 0 {
                logger.error("openOnViewer: script exited \(p.terminationStatus)")
            }
        }
        do { try proc.run() } catch {
            logger.error("openOnViewer: \(error.localizedDescription, privacy: .public)")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Back to opening here. Safe to call when nothing was ever published.
    static func clear(key: String) {
        guard !key.isEmpty else { return }
        try? FileManager.default.removeItem(at: viewersDirectory.appendingPathComponent(key))
    }

    private static func scriptSource() -> String? {
        if let bundled = Bundle.main.path(forResource: "canopy-remote-open", ofType: "sh") {
            return bundled
        }
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = projectRoot.appendingPathComponent("Resources/canopy-remote-open.sh").path
        return FileManager.default.fileExists(atPath: devPath) ? devPath : nil
    }
}
