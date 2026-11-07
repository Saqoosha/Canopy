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
        case rejected(reason: String)
        case malformed
    }

    /// `wire` is the `response` field of the CLI's `control_response`.
    static func parseReply(_ wire: [String: Any]) -> CLIReply {
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
            return reason == "busy" ? .busy : .rejected(reason: reason)
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

    static func next(after reply: CLIReply, retries: Int) -> Next {
        switch reply {
        case .ok(let cwd, let changed):
            return changed ? .restart(URL(fileURLWithPath: cwd, isDirectory: true)) : .stay
        case .needsTrust(let directory, let trustRoot):
            return .askTrust(directory: directory, trustRoot: trustRoot)
        case .busy:
            return retries < busyRetryLimit ? .retry : .fail("The session stayed busy.")
        case .rejected(let reason):
            return .fail("Claude Code refused the folder (\(reason)).")
        case .malformed:
            return .fail("Claude Code gave an answer Canopy could not read.")
        }
    }

    /// Why this session cannot move, or nil.
    static func refusal(isRemote: Bool, isInWorktree: Bool, path: String,
                        isDirectory: (String) -> Bool) -> String? {
        if isRemote { return "An SSH remote session cannot move." }
        if isInWorktree { return "A session inside a worktree cannot move." }
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
        case accepted, declined, unanswered
    }

    struct TrustPrompt: Equatable {
        let header: String
        let message: String
    }

    static func trustPrompt(directory: String, trustRoot: String?) -> TrustPrompt {
        var message = "Claude Code will trust \(directory) and may run its hooks and MCP servers."
        if let trustRoot, trustRoot != directory { message += " The trust covers everything under \(trustRoot)." }
        return TrustPrompt(header: "Move this session to \((directory as NSString).lastPathComponent)?", message: message)
    }

    /// Only the Move button, pressed, is a yes. A timeout is a failed read with the cancel response.
    static func trustAnswer(result: Int32, flags: CFOptionFlags) -> TrustAnswer {
        guard result == 0 else { return .unanswered }
        switch flags & 3 {
        case CFOptionFlags(kCFUserNotificationAlternateResponse): return .accepted
        case CFOptionFlags(kCFUserNotificationDefaultResponse): return .declined
        default: return .unanswered
        }
    }

    /// A system alert raised by this process, so the answer never crosses the control
    /// socket, where anything a session runs could give it. Blocks; call it off the main thread.
    static func askTrust(directory: String, trustRoot: String?) -> TrustAnswer {
        let prompt = trustPrompt(directory: directory, trustRoot: trustRoot)
        // Cancel is the default button, so a stray Return is not a yes.
        let alert: [CFString: Any] = [
            kCFUserNotificationAlertHeaderKey: prompt.header,
            kCFUserNotificationAlertMessageKey: prompt.message,
            kCFUserNotificationDefaultButtonTitleKey: "Cancel",
            kCFUserNotificationAlternateButtonTitleKey: "Move",
        ]
        var error: Int32 = 0
        guard let note = CFUserNotificationCreate(nil, trustTimeout, CFOptionFlags(kCFUserNotificationCautionAlertLevel),
                                                  &error, alert as CFDictionary) else {
            logger.error("Could not raise the trust alert: \(error, privacy: .public)")
            return .unanswered
        }
        var flags: CFOptionFlags = 0
        let result = CFUserNotificationReceiveResponse(note, trustTimeout, &flags)
        return trustAnswer(result: result, flags: flags)
    }

    /// A system alert too: the failure banner lives on the launcher, and the pane shows the session.
    static func notifyFailure(_ reason: String) {
        logger.error("Session not moved: \(reason, privacy: .public)")
        CFUserNotificationDisplayNotice(0, CFOptionFlags(kCFUserNotificationCautionAlertLevel), nil, nil, nil,
                                        "Session not moved" as CFString, reason as CFString, nil)
    }
}
