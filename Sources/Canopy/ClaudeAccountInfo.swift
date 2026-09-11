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
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("\(url.lastPathComponent, privacy: .public) is not a JSON object")
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
        } catch {
            logger.error("Reading \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
