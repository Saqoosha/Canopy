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

    /// With a `trustRoot` the CLI grants the whole repository, worktrees included.
    static func trustPrompt(directory: String, trustRoot: String?, sessionTitle: String) -> TrustPrompt {
        let scope = trustRoot.map { "the repository at \($0), worktrees included," } ?? "\(directory) and everything in it,"
        return TrustPrompt(
            header: "Move “\(sessionTitle)” to \((directory as NSString).lastPathComponent)?",
            message: "Claude Code will trust \(scope) and may run its hooks and MCP servers.")
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

    /// A system alert raised by this process, so the answer never crosses the control
    /// socket. Blocks; call it off the main thread.
    static func askTrust(directory: String, trustRoot: String?, sessionTitle: String) -> TrustAnswer {
        let alert = trustAlert(trustPrompt(directory: directory, trustRoot: trustRoot, sessionTitle: sessionTitle))
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
