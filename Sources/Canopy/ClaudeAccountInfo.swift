import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ClaudeAccountInfo")

/// The `oauthAccount` the CLI last recorded in `~/.claude.json` — the Keychain
/// blob has no email. Normally the signed-in account; a CLI authenticating
/// with an API key leaves a stale one in place.
struct ClaudeAccountInfo {
    let email: String
    let displayName: String?
    let organizationName: String?

    /// Keyed by mtime: the sidebar footer asks on every body evaluation, the
    /// file changes far less often. A parse failure is cached too, until the
    /// next rewrite.
    @MainActor private static var cache: (mtime: Date, info: ClaudeAccountInfo?)?

    @MainActor
    static func current() -> ClaudeAccountInfo? {
        let url = configURL()
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            cache = nil
            return nil
        }
        if let cache, cache.mtime == mtime { return cache.info }
        let info = parse(url)
        cache = (mtime, info)
        return info
    }

    private static func configURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    private static func parse(_ url: URL) -> ClaudeAccountInfo? {
        do {
            return try parse(data: Data(contentsOf: url), source: url.lastPathComponent)
        } catch {
            logger.error("Reading \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The `oauthAccount` in one `.claude.json`'s bytes. Nil when the file is
    /// not a JSON object (logged), or carries no account with an email.
    static func parse(data: Data, source: String) -> ClaudeAccountInfo? {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.error("Parsing \(source, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let root = json as? [String: Any] else {
            logger.warning("\(source, privacy: .public) is not a JSON object")
            return nil
        }
        guard let account = root["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty
        else { return nil }
        func nonEmpty(_ key: String) -> String? {
            (account[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ClaudeAccountInfo(email: email,
                                 displayName: nonEmpty("displayName"),
                                 organizationName: nonEmpty("organizationName"))
    }

    // MARK: - Remote

    /// The account a remote host's CLI is signed in as, read over SSH. Nil
    /// when the host cannot be reached, has no `.claude.json`, or its
    /// `oauthAccount` has no email — the caller cannot tell those apart, and
    /// keys the host's rate limits by host name instead.
    ///
    /// The whole file comes across (a few hundred KB) rather than a remote
    /// `python3 -c` extract: the CLI's native binary needs no interpreter on
    /// the host, so none can be assumed there. The command runs under
    /// `/bin/sh` explicitly because ssh hands it to the login shell, and on a
    /// fish host `${CLAUDE_CONFIG_DIR:-$HOME}` is a syntax error (measured on
    /// `studio`) — the same reason `RemoteSessionHistory` pipes into `/bin/sh`.
    static func remote(host: String) -> ClaudeAccountInfo? {
        guard RemoteSessionHistory.isSpawnableHost(host) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            host,
            #"/bin/sh -c 'cat "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"'"#,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("ssh launch failed for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            logger.warning("\(host, privacy: .public): reading .claude.json exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return parse(data: data, source: "\(host):.claude.json")
    }
}
