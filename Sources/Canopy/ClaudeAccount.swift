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

    /// The sidebar row's context menu is built on every body evaluation, so
    /// `load()` is too; decode once and drop the copy on `save`.
    nonisolated(unsafe) private static var cached: [ClaudeAccount]?

    static func load() -> [ClaudeAccount] {
        if let cached { return cached }
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        do {
            let accounts = try JSONDecoder().decode([ClaudeAccount].self, from: data)
            cached = accounts
            return accounts
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
        cached = nil
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
    /// which the CLI would refuse, and for one `isSafeConfigDir` rejects.
    static func normalizedConfigDir(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return isSafeConfigDir(path) ? path : nil
    }

    /// Sync moves real entries aside and plants links, so it must only ever
    /// run on a directory of its own. Refused: the base dir itself or any
    /// directory inside it, and the home directory or any ancestor of it or
    /// of the base — typing `~` would otherwise rearrange the home folder.
    /// Compared after resolving symlinks, so an alias of the base is caught.
    /// An existing directory must also look like a config dir of its own —
    /// empty, holding `.claude.json` or `.canopy-aside`, or already holding a
    /// link into the base from an earlier sync — so pointing at a repo or
    /// `~/Documents` does not move its `CLAUDE.md` aside.
    static func isSafeConfigDir(_ path: String, base: URL = ClaudeConfigDirSync.baseLocations().dir,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // Lowercased because APFS is case-insensitive by default: `~/.Claude`
        // is the base. Errs toward refusing on a case-sensitive volume.
        func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        let dir = resolved(URL(fileURLWithPath: path, isDirectory: true))
        func isSameOrInside(_ a: String, _ b: String) -> Bool {
            a == b || a.hasPrefix(b == "/" ? "/" : b + "/")
        }
        let basePath = resolved(base)
        let homePath = resolved(home)
        if isSameOrInside(dir, basePath) { return false }
        if isSameOrInside(basePath, dir) || isSameOrInside(homePath, dir) { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let meaningful = entries.filter { $0 != ".DS_Store" }
        let hasBaseLink = meaningful.contains { name in
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(
                atPath: (path as NSString).appendingPathComponent(name)) else { return false }
            return isSameOrInside(resolved(URL(fileURLWithPath: dest)), basePath)
        }
        return meaningful.isEmpty
            || meaningful.contains(".claude.json")
            || meaningful.contains(ClaudeConfigDirSync.asideDirName)
            || hasBaseLink
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
    /// honouring an inherited `CLAUDE_CONFIG_DIR` the same way
    /// `ClaudeAccountInfo.current()` does.
    static func baseLocations() -> (dir: URL, json: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            return (url, url.appendingPathComponent(".claude.json"))
        }
        return (home.appendingPathComponent(".claude", isDirectory: true),
                home.appendingPathComponent(".claude.json"))
    }

    /// Runs before every shim spawn on this account. A failure skips that
    /// entry, not the session.
    static func sync(_ account: ClaudeAccount) {
        let (baseDir, baseJSON) = baseLocations()
        let dir = account.configURL
        guard ClaudeAccountStore.isSafeConfigDir(account.configDir, base: baseDir) else {
            logger.error("Refusing to sync account \(account.name, privacy: .public): its directory overlaps the default config or home directory, or is not a config directory")
            return
        }
        linkEntries(from: baseDir, into: dir)
        syncMCPServers(from: baseJSON, into: dir.appendingPathComponent(".claude.json"))
    }

    static func linkEntries(from base: URL, into dir: URL) {
        let fm = FileManager.default
        // One spelling for both the links written and the stale-link sweep.
        let baseDir = base.standardizedFileURL
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
            // Any existing link is left alone.
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }
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
        let basePrefix = baseDir.path + "/"
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
    /// The CLI rewrites this file too: a CLI write landing between this read
    /// and the swap is lost. Written only when the servers differ.
    static func syncMCPServers(from baseJSON: URL, into accountJSON: URL) {
        guard let baseData = try? Data(contentsOf: baseJSON),
              let base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else {
            logger.warning("Base .claude.json unreadable; MCP servers not synced")
            return
        }
        let servers = (base["mcpServers"] as? [String: Any]) ?? [:]
        // Never overwrite a file we cannot read — it holds the login. Only a
        // file that does not exist yet starts empty.
        var account: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: accountJSON.path) {
            guard let data = try? Data(contentsOf: accountJSON),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                logger.error("Account .claude.json unreadable; MCP servers not synced")
                return
            }
            account = parsed
        }
        let current = (account["mcpServers"] as? [String: Any]) ?? [:]
        guard !NSDictionary(dictionary: current).isEqual(to: servers) else { return }
        account["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(withJSONObject: account, options: [.prettyPrinted])
            // Created 0600 before any byte lands — `mcpServers` can carry
            // secrets — then swapped in, so the file is never readable by
            // others and never half-written.
            let fm = FileManager.default
            let temp = accountJSON.deletingLastPathComponent()
                .appendingPathComponent(".claude.json.canopy-\(UUID().uuidString)")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                logger.error("Cannot create temp .claude.json: errno \(errno)")
                return
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            // rename(2), not `replaceItemAt`: that one carries the old file's
            // mode over the new one.
            guard rename(temp.path, accountJSON.path) == 0 else {
                let code = errno
                try? fm.removeItem(at: temp)
                logger.error("Cannot replace account .claude.json: errno \(code)")
                return
            }
            logger.notice("Synced \(servers.count) MCP server(s) into an account's .claude.json")
        } catch {
            logger.error("Cannot write account .claude.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
