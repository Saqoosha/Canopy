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

    /// One thing the destination's own Claude Code files set. `stops` is true for what
    /// runs by itself once trusted or widens what runs unasked; only those raise the alert.
    struct FolderFinding: Equatable {
        let text: String
        let stops: Bool
    }

    /// With a `trustRoot` the CLI grants the whole repository, worktrees included.
    static func trustPrompt(directory: String, trustRoot: String?, sessionTitle: String,
                            findings: [FolderFinding]) -> TrustPrompt {
        let scope = trustRoot.map { "the repository at \($0), worktrees included," } ?? "\(directory) and everything in it,"
        var lines = findings.map { "• \($0.text)" }
        if lines.count > findingsLineLimit {
            let rest = lines.count - (findingsLineLimit - 1)
            lines = Array(lines.prefix(findingsLineLimit - 1)) + ["• and \(rest) more"]
        }
        return TrustPrompt(
            header: "Move “\(sessionTitle)” to \((directory as NSString).lastPathComponent)?",
            message: "Claude Code will trust \(scope) and run what this folder sets:\n"
                + lines.joined(separator: "\n"))
    }

    static func shouldAsk(_ findings: [FolderFinding]) -> Bool { findings.contains(where: \.stops) }

    static let findingsLineLimit = 12
    static let findingsTextLimit = 100

    /// Settings keys that do not stop. Anything else does, so a key this list does not know,
    /// `env` or `enabledPlugins` say, fails closed. `enabledMcpjsonServers` and kin act only
    /// through `.mcp.json`, which stops by itself.
    static let quietSettingsKeys: Set<String> = [
        "permissions", "enabledMcpjsonServers", "enableAllProjectMcpServers", "disabledMcpjsonServers",
        "outputStyle", "plansDirectory",
    ]
    static let quietPermissionModes: Set<String> = ["default", "plan"]

    /// Reads `directory`'s own `.claude/settings.json`, `.claude/settings.local.json`,
    /// `.mcp.json` and `CLAUDE.md`, not its parents'. `read` returns a file's bytes or nil.
    /// Fails closed: only `quietSettingsKeys`, `permissions.deny`/`ask`, a mode in
    /// `quietPermissionModes`, and allow rules in `settings.local.json` do not stop. Those
    /// allow rules are the file Claude Code writes when the user picks "always allow"
    /// (measured: every allow rule in ~/repos on both Macs, 2026-11-11); `settings.json`
    /// is the one a clone brings, so its allow rules stop. Any `.mcp.json` stops, and so
    /// does a file that is not a JSON object.
    static func folderFindings(directory: String, read: (String) -> Data?) -> [FolderFinding] {
        var found: [FolderFinding] = []
        func add(_ text: String, stops: Bool = true) {
            // Folder text in a system alert: one line each, so it cannot fake the alert's own wording.
            let flat = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
            }))
            found.append(FolderFinding(
                text: flat.count > findingsTextLimit ? String(flat.prefix(findingsTextLimit - 1)) + "…" : flat,
                stops: stops))
        }
        func json(_ name: String) -> [String: Any]? {
            guard let data = read((directory as NSString).appendingPathComponent(name)) else { return nil }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                add("\(name) that is not a JSON object")
                return nil
            }
            return object
        }
        for name in [".claude/settings.json", ".claude/settings.local.json"] {
            guard let settings = json(name) else { continue }
            for key in settings.keys.sorted() {
                switch key {
                case "hooks":
                    let hooks = settings[key] as? [String: Any] ?? [:]
                    var any = false
                    for event in hooks.keys.sorted() {
                        for group in hooks[event] as? [[String: Any]] ?? [] {
                            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                                let what = hook["command"] as? String ?? hook["url"] as? String
                                    ?? hook["prompt"] as? String ?? (hook["type"] as? String ?? "?")
                                add("hook \(event): \(what)")
                                any = true
                            }
                        }
                    }
                    if !any, !hooks.isEmpty { add("hooks") }
                case "statusLine":
                    add("status line: \((settings[key] as? [String: Any])?["command"] as? String ?? "?")")
                case "apiKeyHelper":
                    add("API key helper: \(settings[key] as? String ?? "?")")
                case "permissions":
                    let permissions = settings[key] as? [String: Any] ?? [:]
                    for sub in permissions.keys.sorted() {
                        switch sub {
                        case "allow":
                            let allow = permissions[sub] as? [String] ?? []
                            if !allow.isEmpty {
                                add("allows without asking: \(allow.joined(separator: ", "))",
                                    stops: name == ".claude/settings.json")
                            }
                        case "deny", "ask":
                            continue
                        case "defaultMode":
                            let mode = permissions[sub] as? String ?? "?"
                            add("permission mode: \(mode)", stops: !quietPermissionModes.contains(mode))
                        default:
                            add("sets permissions.\(sub)")
                        }
                    }
                case _ where quietSettingsKeys.contains(key):
                    continue
                default:
                    add("sets \(key)")
                }
            }
        }
        if let mcp = json(".mcp.json") {
            let servers = mcp["mcpServers"] as? [String: Any] ?? [:]
            for name in servers.keys.sorted() {
                let server = servers[name] as? [String: Any] ?? [:]
                let what = server["command"].map { command in
                    ([command] + (server["args"] as? [Any] ?? [])).map { "\($0)" }.joined(separator: " ")
                } ?? server["url"] as? String ?? "?"
                add("MCP server \(name): \(what)")
            }
            if servers.isEmpty { add(".mcp.json") }
        }
        if read((directory as NSString).appendingPathComponent("CLAUDE.md")) != nil { add("CLAUDE.md", stops: false) }
        return found
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

    /// Accepts unasked when the folder sets nothing that stops (`folderFindings`): such a
    /// folder lets a session do nothing it cannot already do where it is. Otherwise a
    /// system alert raised by this process, so the answer never crosses the control
    /// socket. Blocks; call it off the main thread.
    static func askTrust(directory: String, trustRoot: String?, sessionTitle: String) -> TrustAnswer {
        // The CLI trusts the repository root too, so a later session there runs its files unasked.
        let findings = Array(Set([directory] + [trustRoot].compactMap { $0 })).sorted().flatMap {
            folderFindings(directory: $0) { FileManager.default.contents(atPath: $0) }
        }
        guard shouldAsk(findings) else {
            logger.notice("Trusting \(directory, privacy: .public) unasked: it sets nothing that runs by itself")
            return .accepted
        }
        let alert = trustAlert(trustPrompt(directory: directory, trustRoot: trustRoot, sessionTitle: sessionTitle,
                                           findings: findings))
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
