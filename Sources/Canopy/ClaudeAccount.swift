import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ClaudeAccount")

/// A second Claude login, selected per session by pointing the CLI at another
/// `CLAUDE_CONFIG_DIR`. The default account is not an entry: it is `nil`
/// everywhere a `ClaudeAccount?` appears, and means "whatever the inherited
/// environment says" — normally `~/.claude`.
///
/// Measured against CLI 2.1.258 before this was built:
/// - The CLI keys its Keychain item by the config dir's path
///   (`Claude Code-credentials-<first 8 hex of sha256(path)>`), so a dir holds
///   its own login and an empty one reports `Not logged in` rather than
///   falling back to the default credential. Moving the dir loses the login.
/// - The path must be absolute; the CLI refuses a relative one.
/// - Transcripts land in `<dir>/projects`, so resuming a session under another
///   account only works while `projects` is shared — `ClaudeConfigDirSync`
///   makes it a symlink.
/// - The extension reads `CLAUDE_CONFIG_DIR` itself and passes no token to the
///   CLI, so setting it on the shim is enough for both.
struct ClaudeAccount: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    /// Absolute path. Stored with `~` expanded.
    var configDir: String

    var configURL: URL { URL(fileURLWithPath: configDir, isDirectory: true) }
}

enum ClaudeAccountStore {
    private static let accountsKey = "claudeAccounts"
    private static let defaultKey = "defaultClaudeAccountId"

    static func load() -> [ClaudeAccount] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        do {
            return try JSONDecoder().decode([ClaudeAccount].self, from: data)
        } catch {
            logger.error("Failed to decode Claude accounts: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func save(_ accounts: [ClaudeAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else {
            logger.error("Failed to encode Claude accounts")
            return
        }
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    static func account(id: String?) -> ClaudeAccount? {
        guard let id, !id.isEmpty else { return nil }
        return load().first { $0.id == id }
    }

    /// The account new sessions start on. Nil is the default login.
    static func defaultAccount() -> ClaudeAccount? {
        account(id: UserDefaults.standard.string(forKey: defaultKey))
    }

    static func defaultAccountId() -> String {
        UserDefaults.standard.string(forKey: defaultKey) ?? ""
    }

    static func setDefault(_ id: String?) {
        UserDefaults.standard.set(id ?? "", forKey: defaultKey)
    }

    static func delete(_ id: String) {
        save(load().filter { $0.id != id })
        if defaultAccountId() == id { setDefault(nil) }
    }

    /// `~` expanded and made absolute; nil for an empty or relative path,
    /// which the CLI would refuse.
    static func normalizedConfigDir(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

/// Keeps an account's config dir sharing everything with the default one
/// except the login itself.
///
/// Every top-level entry of the base dir is linked into the account's dir, so
/// CLAUDE.md, rules, hooks, skills, output styles and `projects` stay one copy
/// and edits show up in both. What cannot be linked is `.claude.json`: it
/// lives in the account's dir and holds that account's `oauthAccount`. Its
/// user-scope `mcpServers` are copied over from the base instead, since that
/// is the only place the CLI keeps them.
enum ClaudeConfigDirSync {
    /// Entries that belong to one login and must not be shared. `backups`
    /// holds copies of `.claude.json`, which would mix the two accounts'.
    static let unsharedEntries: Set<String> = [".claude.json", "backups", ".DS_Store"]

    /// Where a real entry the account dir already had goes when it is
    /// replaced by a link — moved, never deleted.
    static let asideDirName = ".canopy-aside"

    /// The default config dir and the `.claude.json` that goes with it,
    /// honouring an inherited `CLAUDE_CONFIG_DIR` the same way the CLI does.
    static func baseLocations() -> (dir: URL, json: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            return (url, url.appendingPathComponent(".claude.json"))
        }
        return (home.appendingPathComponent(".claude", isDirectory: true),
                home.appendingPathComponent(".claude.json"))
    }

    /// Runs before every shim spawn on this account. Cheap — one directory
    /// listing each side, plus one small JSON read — and every failure is
    /// logged and skipped: a missing link costs a setting, not the session.
    static func sync(_ account: ClaudeAccount) {
        let (baseDir, baseJSON) = baseLocations()
        let dir = account.configURL
        guard dir.standardizedFileURL.path != baseDir.standardizedFileURL.path else { return }
        linkEntries(from: baseDir, into: dir)
        syncMCPServers(from: baseJSON, into: dir.appendingPathComponent(".claude.json"))
    }

    static func linkEntries(from baseDir: URL, into dir: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Cannot create account dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        let baseNames: [String]
        do {
            baseNames = try fm.contentsOfDirectory(atPath: baseDir.path)
        } catch {
            logger.error("Cannot list base config dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        let wanted = Set(baseNames).subtracting(unsharedEntries)
        for name in wanted {
            let link = dir.appendingPathComponent(name)
            let target = baseDir.appendingPathComponent(name).path
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if existing == target { continue }
                // A link somewhere else was put there by hand; leave it.
                continue
            }
            if fm.fileExists(atPath: link.path) {
                // A real entry — usually one the CLI created when the account
                // was logged in, before anything was linked. Moved aside so
                // the shared copy wins and nothing is lost.
                let aside = dir.appendingPathComponent(asideDirName, isDirectory: true)
                do {
                    try fm.createDirectory(at: aside, withIntermediateDirectories: true)
                    let dest = aside.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))")
                    try fm.moveItem(at: link, to: dest)
                    logger.notice("Moved account-local \(name, privacy: .public) aside to share the default one")
                } catch {
                    logger.error("Cannot move \(name, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            do {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            } catch {
                logger.error("Cannot link \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Links into the base that should not be there: an entry that is gone
        // (so a deleted setting does not linger), or one of `unsharedEntries`
        // linked by hand.
        let basePrefix = baseDir.standardizedFileURL.path + "/"
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !wanted.contains(name) {
            let link = dir.appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  dest.hasPrefix(basePrefix),
                  unsharedEntries.contains(name) || !fm.fileExists(atPath: dest) else { continue }
            try? fm.removeItem(at: link)
        }
    }

    /// Copies the base's user-scope `mcpServers` into the account's
    /// `.claude.json` when they differ. The base is the source of truth, so a
    /// server added with `claude mcp add` under the account is replaced — add
    /// servers from the default login.
    ///
    /// The CLI rewrites this file too. The write is atomic (temp + rename, the
    /// way the CLI writes it) and happens only when the servers differ, so it
    /// races a running session's own write only on the spawn right after an
    /// MCP change.
    static func syncMCPServers(from baseJSON: URL, into accountJSON: URL) {
        guard let baseData = try? Data(contentsOf: baseJSON),
              let base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else {
            logger.warning("Base .claude.json unreadable; MCP servers not synced")
            return
        }
        let servers = (base["mcpServers"] as? [String: Any]) ?? [:]
        var account: [String: Any] = [:]
        if let data = try? Data(contentsOf: accountJSON) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Never overwrite a file we cannot read — it holds the login.
                logger.error("Account .claude.json unparseable; MCP servers not synced")
                return
            }
            account = parsed
        }
        let current = (account["mcpServers"] as? [String: Any]) ?? [:]
        guard !NSDictionary(dictionary: current).isEqual(to: servers) else { return }
        account["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(withJSONObject: account, options: [.prettyPrinted])
            try data.write(to: accountJSON, options: .atomic)
            // The CLI keeps this file 0600; an atomic write would leave 0644.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountJSON.path)
            logger.notice("Synced \(servers.count) MCP server(s) into an account's .claude.json")
        } catch {
            logger.error("Cannot write account .claude.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
