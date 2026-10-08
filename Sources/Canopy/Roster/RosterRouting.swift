import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RosterRouting")

/// Routes what the phone sends through the relay (a typed reply, a permission
/// decision) to the shim of the session it names. Shared by whichever process
/// holds the sessions and publishes the roster: the daemon, or the GUI while
/// it still runs sessions itself.
@MainActor
enum RosterRouting {
    static func install(on publisher: RosterPublisher, store: SessionStore) {
        // The publisher owns the socket but not the sessions; this closure is
        // the seam between the two, so a reply arriving from the phone can
        // reach the shim it addresses. Every branch that reports a FAILURE
        // from a live store logs why — the phone has no other way to learn
        // its message never landed. (The shutting-down branch does not: there
        // is no session to name and the subsystem is being torn down.) Since the
        // queue landed, "did not inject" is no longer the same as "did not
        // land": a queued prompt is held by this Mac and reported as a
        // success, and it is the one branch here that deliberately logs
        // nothing, because `submitPhoneReply` has already logged its depth
        // and its gate — strictly more than this site knows.
        //
        // The refusals below are this closure's own three (no store, no
        // session, no shim); `submitPhoneReply` adds the ones waiting cannot
        // fix — blank text, a full queue, and a session waiting on a human.
        // The session id is safe to log `.public`; the reply TEXT never is
        // — it is user content and appears in none of these lines.
        // Every branch returns an outcome now. Each of these used to be a
        // bare `return` that logged locally and told the phone nothing, so a
        // reply the Mac could not use still read as sent — the failure this
        // whole ack path exists to end.
        publisher.onReply = { [weak store] envelope in
            guard let store else { return .refused("Canopy is shutting down") }
            guard let session = RosterReply.target(for: envelope, in: store.openSessions) else {
                logger.notice("roster reply: no open session matches \(envelope.sessionId, privacy: .public)")
                return .refused("That session is not open on this Mac")
            }
            guard let shim = session.shim else {
                logger.notice("roster reply: session \(envelope.sessionId, privacy: .public) has no live shim")
                return .refused("That session is not running — open it on the Mac first")
            }
            switch shim.submitPhoneReply(text: envelope.text, replyId: envelope.replyId) {
            case .injected:
                return .delivered
            case .queued(let why):
                // Deliberately unlogged — see the note above the closure.
                return .queued(why)
            case .refused(let why, _):
                logger.notice("roster reply: session \(envelope.sessionId, privacy: .public) refused — \(why, privacy: .public)")
                return .refused(why)
            }
        }
        // Same seam, for a permission decision instead of a typed reply.
        // `RosterReply.decisionTarget` only answers "which session" — the
        // narrower "is this exact requestId still outstanding" check lives
        // in `applyPermissionDecision` itself, since only that shim's
        // `pendingPermissionRequestIds` can answer it (routing on a session
        // that has since moved on to a different request would otherwise
        // silently do nothing, which `applyPermissionDecision`'s own log
        // line covers).
        publisher.onDecision = { [weak store] envelope in
            guard let store else { return .refused("Canopy is shutting down") }
            guard let session = RosterReply.decisionTarget(for: envelope, in: store.openSessions) else {
                // Say which of the two it was. Reporting an envelope this
                // router refused as "no open session matches" names the one
                // thing that was fine, and it cost a full diagnosis round when
                // `allowAlways` was added everywhere except that gate.
                if !RosterReply.acceptedDecisions.contains(envelope.decision) {
                    logger.notice("roster decision: refusing unrecognized decision \(envelope.decision, privacy: .public)")
                    return .refused("Canopy does not understand that answer")
                }
                logger.notice("roster decision: no open session matches \(envelope.sessionId, privacy: .public)")
                return .refused("That session is not open on this Mac")
            }
            guard let shim = session.shim else {
                logger.notice("roster decision: session \(envelope.sessionId, privacy: .public) has no live shim")
                return .refused("That session is not running — open it on the Mac first")
            }
            // The one refusal that was ALREADY reported honestly, by
            // `decisionDelivered` on the phone — but only as "the relay took
            // it". Now it can say which request went stale.
            guard shim.applyPermissionDecision(requestId: envelope.requestId,
                                               decision: envelope.decision,
                                               answers: envelope.answers) else {
                return .refused("That request is no longer waiting for an answer")
            }
            return .delivered
        }
    }
}
