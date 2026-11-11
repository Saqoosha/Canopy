import CoreFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionMove")

/// Moving a live session to another folder: the CLI's `set_cwd`, then a restart
/// there. See `docs/notes/learnings-session-move.md`.
enum SessionMove {
    /// The CLI answers `busy` right after a turn and accepted 3 s later (measured on 2.1.318).
    static let busyRetryInterval: TimeInterval = 3
    static let busyRetryLimit = 10
    static let trustTimeout: TimeInterval = 60

    enum CLIReply: Equatable {
        case ok(cwd: String, changed: Bool)
        case needsTrust(directory: String, trustRoot: String?)
        case busy
        case rejected(reason: String, message: String?)
        /// The CLI's own error frame, with its text.
        case cliError(String)
        case malformed
    }

    /// `wire` is the `response` field of the CLI's `control_response`.
    static func parseReply(_ wire: [String: Any]) -> CLIReply {
        if wire["subtype"] as? String == "error" { return .cliError(wire["error"] as? String ?? "unknown error") }
        guard let answer = wire["response"] as? [String: Any], let status = answer["status"] as? String else { return .malformed }
        switch status {
        case "ok":
            guard let cwd = answer["cwd"] as? String else { return .malformed }
            return .ok(cwd: cwd, changed: answer["changed"] as? Bool ?? true)
        case "needs_trust":
            guard let directory = answer["directory"] as? String else { return .malformed }
            // A root in another shape would shrink the scan below what the CLI trusts.
            if let root = answer["trust_root"], !(root is String), !(root is NSNull) { return .malformed }
            return .needsTrust(directory: directory, trustRoot: answer["trust_root"] as? String)
        case "rejected":
            guard let reason = answer["reason"] as? String else { return .malformed }
            return reason == "busy" ? .busy : .rejected(reason: reason, message: answer["message"] as? String)
        default:
            return .malformed
        }
    }

    enum Next: Equatable {
        case restart(URL)
        case stay
        case retry
        case askTrust(directory: String, trustRoot: String?)
        case fail(String)
    }

    /// `isCurrentFolder` says whether a path is where the shim runs. The CLI's `changed`
    /// compares with the CLI's own folder, which can be ahead of the shim's.
    static func next(after reply: CLIReply, retries: Int, isCurrentFolder: (String) -> Bool) -> Next {
        switch reply {
        case .ok(let cwd, let changed):
            return changed || !isCurrentFolder(cwd) ? .restart(URL(fileURLWithPath: cwd, isDirectory: true)) : .stay
        case .needsTrust(let directory, let trustRoot):
            return .askTrust(directory: directory, trustRoot: trustRoot)
        case .busy:
            return retries < busyRetryLimit ? .retry : .fail("The session stayed busy.")
        case .rejected(let reason, let message):
            return .fail(message ?? "Claude Code refused the folder (\(reason)).")
        case .cliError(let error):
            return .fail("Claude Code could not move: \(error)")
        case .malformed:
            return .fail("Claude Code gave an answer Canopy could not read.")
        }
    }

    /// What the shim does next for a move.
    enum Action: Equatable {
        case send(requestId: String, path: String, trustedDirectory: String?)
        /// The CLI has moved: record it now (`SessionStore.noteMove`), restart once quiet.
        case record(URL)
        case restart
        case askTrust(directory: String, trustRoot: String?)
        /// Back to waiting for a quiet moment, after `delay`.
        case wait(TimeInterval)
        case fail(String)
        case done
    }

    /// One move in a shim's hands, as a value, so its rules are testable without a CLI.
    struct Latch: Equatable {
        enum Phase: Equatable {
            case queued
            case sent
            case askingTrust(directory: String)
            case moved(URL)
        }

        let id: String
        let path: String
        private(set) var phase: Phase = .queued
        /// Set only by an accepted trust alert.
        private(set) var trustedDirectory: String?
        private(set) var busyRetries = 0

        init(path: String, id: String = UUID().uuidString) {
            self.path = path
            self.id = id
        }

        /// A second request must not replace one past `queued`, or one a person approved.
        var isUnderWay: Bool { phase != .queued || trustedDirectory != nil }

        /// Nil while `blocker` holds, or while the CLI or a person is being asked.
        mutating func whenQuiet(blocker: String?) -> Action? {
            guard blocker == nil else { return nil }
            switch phase {
            case .queued:
                phase = .sent
                return .send(requestId: id, path: path, trustedDirectory: trustedDirectory)
            case .moved:
                return .restart
            case .sent, .askingTrust:
                return nil
            }
        }

        /// Nil for an answer that arrives in any phase but `sent`.
        mutating func answered(_ reply: CLIReply, isCurrentFolder: (String) -> Bool) -> Action? {
            guard phase == .sent else { return nil }
            switch SessionMove.next(after: reply, retries: busyRetries, isCurrentFolder: isCurrentFolder) {
            case .restart(let directory):
                phase = .moved(directory)
                return .record(directory)
            case .stay:
                return .done
            case .retry:
                busyRetries += 1
                phase = .queued
                return .wait(SessionMove.busyRetryInterval)
            case .askTrust(let directory, let trustRoot):
                phase = .askingTrust(directory: directory)
                return .askTrust(directory: directory, trustRoot: trustRoot)
            case .fail(let reason):
                return .fail(reason)
            }
        }

        /// The CLI echoes the directory it asked about, so that is what an accepted answer sends back.
        mutating func trustAnswered(_ answer: TrustAnswer) -> Action? {
            guard case .askingTrust(let directory) = phase else { return nil }
            switch answer {
            case .accepted:
                trustedDirectory = directory
                phase = .queued
                return .wait(0)
            case .declined:
                return .done
            case .unanswered:
                return .fail("Nobody confirmed the folder in time.")
            case .couldNotAsk:
                return .fail("Canopy could not ask about the folder on this Mac's screen.")
            }
        }
    }

    /// Why this session cannot move, or nil.
    static func refusal(isRemote: Bool, isInWorktree: Bool, path: String,
                        isDirectory: (String) -> Bool) -> String? {
        if isRemote { return "An SSH remote session cannot move." }
        if isInWorktree { return "A session in a worktree cannot move." }
        guard path.hasPrefix("/") else { return "The folder must be an absolute path." }
        return isDirectory(path) ? nil : "\(path) is not a folder."
    }

    /// By the folder the session is really in: it can enter a worktree after it starts.
    /// Runs `git`, so call it off the main thread.
    static func isInWorktree(jsonlPath: String?, workingDirectory: URL) -> Bool {
        let effective = ShimProcess.effectiveVCSDirectory(jsonlPath: jsonlPath, workingDirectory: workingDirectory)
        return GitWorktree.isManagedWorktree(effective) || GitWorktree.checkoutOfWorktreeRoot(effective) != nil
    }

    enum TrustAnswer: Equatable {
        case accepted, declined, unanswered, couldNotAsk
    }

    struct TrustPrompt: Equatable {
        let header: String
        let message: String
    }

    /// What makes a folder's trust worth asking about: a `.claude` folder (settings can run
    /// hooks or widen permissions; agents and skills can declare MCP servers and allowed
    /// tools) or a `.mcp.json`. Their contents never decide anything: Foundation's JSON
    /// parser keeps the first duplicate key and the CLI's keeps the last (measured), so a
    /// scan cannot vouch for what the CLI reads.
    static let claudeFolderName = ".claude"
    static let mcpFileName = ".mcp.json"
    static let scopeEntryLimit = 500_000

    enum ScopeScan: Equatable {
        /// No config file anywhere in the scope.
        case clean
        /// The folders holding config files, each relative to its scan root ("" for the root).
        case configs([String])
        /// Not checked to the end, so it counts as config found.
        case unchecked(String)
    }

    /// The folder holding Claude Code config when `relative`, a path under a scan root,
    /// is or is inside a `.claude` folder, or is a `.mcp.json`; else nil.
    static func configFolder(_ relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        if let claude = parts.firstIndex(of: claudeFolderName) { return parts[..<claude].joined(separator: "/") }
        if parts.last == mcpFileName { return parts.dropLast().joined(separator: "/") }
        return nil
    }

    /// Every entry under each root. `walk` yields root-relative paths and returns false
    /// when it could not read everything; the walk stops once `yield` returns false.
    static func scanScope(roots: [String], walk: (String, (String) -> Bool) -> Bool) -> ScopeScan {
        var folders: [String] = []
        var seen = 0
        for root in roots {
            var tooMany = false
            let complete = walk(root) { relative in
                seen += 1
                if seen > scopeEntryLimit { tooMany = true; return false }
                if let folder = configFolder(relative) {
                    folders.append(folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder))
                }
                return true
            }
            if tooMany { return .unchecked("more than \(scopeEntryLimit) files") }
            if !complete { return .unchecked("part of \(root) could not be read") }
        }
        var unique: [String] = []
        for folder in folders where !unique.contains(folder) { unique.append(folder) }
        return unique.isEmpty ? .clean : .configs(unique)
    }

    /// What trusting `directory` covers: `trustRoot` and every worktree of its repository,
    /// or `directory` and everything in it. Nil when the worktrees could not be listed.
    static func trustScope(directory: String, trustRoot: String?, worktreeList: (String) -> String?) -> [String]? {
        guard let trustRoot else { return [directory] }
        guard let listing = worktreeList(trustRoot) else { return nil }
        let checkouts = GitWorktree.checkouts(worktreeListPorcelainZ: listing)
        var roots = [trustRoot]
        for path in [checkouts.main].compactMap({ $0 }) + checkouts.linked where !roots.contains(path) {
            roots.append(path)
        }
        return roots
    }

    /// GitHub owners whose repositories' committed config the user vouches for. Empty
    /// unless set: `defaults write <bundle id> canopy.trustedRemoteOwners -array <owner>…`.
    static let trustedRemoteOwnersKey = "canopy.trustedRemoteOwners"
    static var trustedRemoteOwners: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: trustedRemoteOwnersKey) ?? []).map { $0.lowercased() })
    }

    /// Whether `url` is a github.com repository of one of `owners` (lowercased), in https,
    /// scp-like or ssh form. Any other host, including one that only starts with
    /// github.com, is not.
    static func isOwnRemote(_ url: String, owners: Set<String>) -> Bool {
        var rest = Substring(url.lowercased())
        for scheme in ["https://", "ssh://", "git://"] where rest.hasPrefix(scheme) { rest = rest.dropFirst(scheme.count) }
        if let at = rest.firstIndex(of: "@"), !rest[..<at].contains("/") { rest = rest[rest.index(after: at)...] }
        guard rest.hasPrefix("github.com"), let separator = rest.dropFirst("github.com".count).first,
              separator == "/" || separator == ":" else { return false }
        let owner = rest.dropFirst("github.com".count + 1).split(separator: "/").first.map(String.init) ?? ""
        return !owner.isEmpty && owners.contains(owner)
    }

    /// A walk over what git tracks: config that came with a clone or a pull. Untracked
    /// config was made on this Mac, by the user or by a session that already has Bash.
    static func walkTracked(_ root: String, _ yield: (String) -> Bool,
                            list: (String) -> [String]? = { GitWorktree.trackedPaths(in: $0) }) -> Bool {
        guard let paths = list(root) else { return false }
        for path in paths where !yield(path) { return false }
        return true
    }

    /// A walk that fails closed: an unreadable folder makes it incomplete. Symlinked
    /// folders are not followed, because the CLI trusts by path.
    static func walkFiles(_ root: String, _ yield: (String) -> Bool) -> Bool {
        var complete = true
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in complete = false; return true }) else { return false }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return false }
            if !yield(String(path.dropFirst(prefix.count))) { return false }
        }
        return complete
    }

    static let summaryLineLimit = 12
    static let summaryTextLimit = 100
    static let summaryFileLimit = 1 << 20

    /// For the alert only: what the config files in `folder` set. Best effort, since the
    /// alert has already been decided on. `read` returns a regular file's bytes or nil.
    static func configSummary(folder: String, read: (String) -> Data?) -> [String] {
        var lines: [String] = []
        let name = (folder as NSString).lastPathComponent
        let claude = (folder as NSString).appendingPathComponent(claudeFolderName)
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: claude)) ?? [])
            .filter { $0 != "settings.json" && $0 != "settings.local.json" }.sorted()
        if !others.isEmpty { lines.append("\(name)/.claude: \(others.joined(separator: ", "))") }
        for file in [".claude/settings.json", ".claude/settings.local.json", mcpFileName] {
            let path = (folder as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) || read(path) != nil else { continue }
            guard let data = read(path),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                lines.append("\(name)/\(file): not shown")
                continue
            }
            if file == mcpFileName {
                let servers = json["mcpServers"] as? [String: Any] ?? [:]
                for server in servers.keys.sorted() {
                    let entry = servers[server] as? [String: Any] ?? [:]
                    let what = entry["command"].map { command in
                        ([command] + (entry["args"] as? [Any] ?? [])).map { "\($0)" }.joined(separator: " ")
                    } ?? entry["url"] as? String ?? "?"
                    lines.append("\(name): MCP server \(server): \(what)")
                }
                if servers.isEmpty { lines.append("\(name)/\(file)") }
                continue
            }
            var parts: [String] = []
            for key in json.keys.sorted() {
                switch key {
                case "hooks":
                    let hooks = json[key] as? [String: Any] ?? [:]
                    for event in hooks.keys.sorted() {
                        for group in hooks[event] as? [[String: Any]] ?? [] {
                            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                                let what = hook["command"] as? String ?? hook["url"] as? String
                                    ?? hook["prompt"] as? String ?? (hook["type"] as? String ?? "?")
                                lines.append("\(name): hook \(event): \(what)")
                            }
                        }
                    }
                case "permissions":
                    let permissions = json[key] as? [String: Any] ?? [:]
                    if let allow = permissions["allow"] as? [Any], !allow.isEmpty {
                        lines.append("\(name): allows \(allow.map { "\($0)" }.joined(separator: ", "))")
                    }
                    if let mode = permissions["defaultMode"] { lines.append("\(name): permission mode \(mode)") }
                    parts += permissions.keys.filter { $0 != "allow" && $0 != "defaultMode" }.sorted().map { "permissions.\($0)" }
                default:
                    parts.append(key)
                }
            }
            if !parts.isEmpty { lines.append("\(name)/\(file): \(parts.joined(separator: ", "))") }
        }
        return lines
    }

    /// With a `trustRoot` the CLI grants the whole repository, worktrees included.
    static func trustPrompt(directory: String, trustRoot: String?, sessionTitle: String,
                            scan: ScopeScan, summary: [String]) -> TrustPrompt {
        let scope = trustRoot.map { "the repository at \($0), worktrees included," } ?? "\(directory) and everything in it,"
        let reason: String
        switch scan {
        case .clean: reason = "It has no Claude Code settings."
        case .configs(let folders): reason = "Claude Code settings in \(folders.joined(separator: ", ")):"
        case .unchecked(let why): reason = "Canopy could not check it all: \(why)."
        }
        // Folder text in a system alert: one line each, so it cannot fake the alert's own wording.
        var lines = summary.map { text -> String in
            let flat = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
            }))
            return "• " + (flat.count > summaryTextLimit ? String(flat.prefix(summaryTextLimit - 1)) + "…" : flat)
        }
        if lines.count > summaryLineLimit {
            let rest = lines.count - (summaryLineLimit - 1)
            lines = Array(lines.prefix(summaryLineLimit - 1)) + ["• and \(rest) more"]
        }
        return TrustPrompt(
            header: "Move “\(sessionTitle)” to \((directory as NSString).lastPathComponent)?",
            message: "Claude Code will trust \(scope) and may run its hooks and MCP servers. \(reason)"
                + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")))
    }

    /// Only the Move button, pressed, is a yes. A failed read never is.
    static func trustAnswer(result: Int32, flags: CFOptionFlags) -> TrustAnswer {
        guard result == 0 else { return .unanswered }
        switch flags & 3 {
        case CFOptionFlags(kCFUserNotificationAlternateResponse): return .accepted
        case CFOptionFlags(kCFUserNotificationDefaultResponse): return .declined
        default: return .unanswered
        }
    }

    /// Move is the alternate button, the one `trustAnswer` accepts. Cancel is the default,
    /// so a stray Return is not a yes.
    static func trustAlert(_ prompt: TrustPrompt) -> [CFString: Any] {
        [
            kCFUserNotificationAlertHeaderKey: prompt.header,
            kCFUserNotificationAlertMessageKey: prompt.message,
            kCFUserNotificationDefaultButtonTitleKey: "Cancel",
            kCFUserNotificationAlternateButtonTitleKey: "Move",
        ]
    }

    /// A regular file's bytes, up to `summaryFileLimit`; nil for a FIFO, device or
    /// anything larger, which would block or never end.
    static func readRegularFile(_ path: String) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? .max) <= summaryFileLimit else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// What the trust covers, checked: a `.mcp.json` in any folder above (the CLI loads
    /// those too); then in a repository, the config git tracks in every checkout, skipped
    /// for an `isOwnRemote` origin; outside one, any config at all.
    static func scanTrust(directory: String, trustRoot: String?, owners: Set<String>,
                          worktreeList: (String) -> String?, origin: (String) -> String?,
                          exists: (String) -> Bool,
                          walkRepository: (String, (String) -> Bool) -> Bool,
                          walkFolder: (String, (String) -> Bool) -> Bool) -> ScopeScan {
        var above = ((trustRoot ?? directory) as NSString).deletingLastPathComponent
        var ancestors: [String] = []
        while true {
            if exists((above as NSString).appendingPathComponent(mcpFileName)) { ancestors.append(above) }
            if above == "/" || above.isEmpty { break }
            above = (above as NSString).deletingLastPathComponent
        }
        if !ancestors.isEmpty { return .configs(ancestors) }
        guard let roots = trustScope(directory: directory, trustRoot: trustRoot, worktreeList: worktreeList) else {
            return .unchecked("its worktrees could not be listed")
        }
        guard let trustRoot else { return scanScope(roots: roots, walk: walkFolder) }
        if let url = origin(trustRoot), isOwnRemote(url, owners: owners) { return .clean }
        return scanScope(roots: roots, walk: walkRepository)
    }

    /// Accepts unasked when `scanTrust` finds nothing: no config came from outside this
    /// Mac, short of commits by `trustedRemoteOwners`. Otherwise a system alert raised by this process, so the answer never
    /// crosses the control socket. Blocks; call it off the main thread.
    static func askTrust(directory: String, trustRoot: String?, sessionTitle: String) -> TrustAnswer {
        let scan = scanTrust(
            directory: directory, trustRoot: trustRoot, owners: trustedRemoteOwners,
            worktreeList: { GitWorktree.worktreeListPorcelainZ(for: URL(fileURLWithPath: $0)) },
            origin: { GitWorktree.originURL(of: $0) },
            exists: { FileManager.default.fileExists(atPath: $0) },
            walkRepository: { walkTracked($0, $1) }, walkFolder: walkFiles)
        if scan == .clean {
            logger.notice("Trusting \(trustRoot ?? directory, privacy: .public) unasked: no Claude Code config from outside")
            return .accepted
        }
        var summary: [String] = []
        if case .configs(let folders) = scan {
            summary = folders.flatMap { configSummary(folder: $0, read: readRegularFile) }
        }
        let alert = trustAlert(trustPrompt(directory: directory, trustRoot: trustRoot, sessionTitle: sessionTitle,
                                           scan: scan, summary: summary))
        var error: Int32 = 0
        guard let note = CFUserNotificationCreate(nil, trustTimeout, CFOptionFlags(kCFUserNotificationCautionAlertLevel),
                                                  &error, alert as CFDictionary) else {
            logger.error("Could not raise the trust alert: \(error, privacy: .public)")
            return .couldNotAsk
        }
        var flags: CFOptionFlags = 0
        let result = CFUserNotificationReceiveResponse(note, trustTimeout, &flags)
        // Off the screen too, or a late Move press would answer nothing.
        if result != 0 { CFUserNotificationCancel(note) }
        return trustAnswer(result: result, flags: flags)
    }

    /// A system alert too: the failure banner lives on the launcher, and the pane shows the session.
    static func notifyFailure(sessionTitle: String, reason: String) {
        logger.error("Session not moved: \(reason, privacy: .public)")
        CFUserNotificationDisplayNotice(0, CFOptionFlags(kCFUserNotificationCautionAlertLevel), nil, nil, nil,
                                        "“\(sessionTitle)” was not moved" as CFString, reason as CFString, nil)
    }
}
