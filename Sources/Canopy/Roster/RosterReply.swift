import Foundation

/// A reply typed on the phone, arriving down the publisher socket.
///
/// The wire shape is fixed by the relay Worker: `{"type":"reply","sessionId":
/// "<uuid string>","text":"<non-empty>"}`. The Worker already rejects
/// empty/whitespace `text` with 400 before it reaches the Durable Object, but
/// `RosterReply.target` refuses it again — a wire contract is not a
/// guarantee, and trusting one side of a socket is how the keep-alive's own
/// swallow bugs happened.
struct ReplyEnvelope: Codable {
    let type: String
    let sessionId: String
    let text: String
    /// Correlates the acknowledgement this Mac sends back. Optional because a
    /// relay older than the ack protocol sends none; the reply is still
    /// injected, and only the confirmation is missing.
    let deliveryId: String?
}

/// A permission decision made on the phone, arriving down the publisher
/// socket.
///
/// The wire shape is fixed by the relay Worker (Task 7): `{"type":
/// "decision","sessionId":"<uuid string>","requestId":"<hex>","decision":
/// "allow"|"deny"}`. The Worker already rejects a `decision` outside that
/// set with 400 and never forwards `"allow_always"` — see
/// `docs/superpowers/specs/2026-09-04-permission-response-capture.md` for
/// why that third value is not a legal `behavior` at all. `decisionTarget`
/// refuses it again for the same reason `target` refuses blank text: a wire
/// contract is not a guarantee.
struct DecisionEnvelope: Codable {
    let type: String
    let sessionId: String
    let requestId: String
    let decision: String
    /// See `ReplyEnvelope.deliveryId`.
    let deliveryId: String?
}

/// What this Mac did with a delivery, sent back so the relay can answer the
/// phone with something true.
///
/// **`ok: false` is the case this exists for.** The socket was alive, so the
/// relay's write succeeded and it used to answer 200 — while the Mac had no
/// such session, no live shim, or a shim that refused. The phone showed the
/// message as sent and nothing had happened.
struct DeliveryOutcome {
    let ok: Bool
    /// Shown on the phone. Never conversation content — these are states, not
    /// text the user wrote.
    let reason: String?

    static let delivered = DeliveryOutcome(ok: true, reason: nil)
    static func refused(_ reason: String) -> DeliveryOutcome {
        DeliveryOutcome(ok: false, reason: reason)
    }
}

enum RosterReply {
    /// Which open session an envelope addresses, or nil.
    ///
    /// Matched on `OpenSession.ID`, which is minted per process — the roster
    /// republishes on every state change, so the phone's ids are always from
    /// the current launch. An id from a previous launch therefore finds
    /// nothing, which is the correct outcome: injecting into "some session"
    /// because the intended one is gone would put words in the wrong
    /// conversation, permanently.
    static func target(for envelope: ReplyEnvelope,
                        in sessions: [OpenSession]) -> OpenSession? {
        guard envelope.type == "reply",
              !envelope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = UUID(uuidString: envelope.sessionId)
        else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The decision values this router will carry. **One list, checked in one
    /// place** — the previous spelling repeated `"allow"` and `"deny"` inline
    /// here while `ShimProcess.applyPermissionDecision` had its own switch, so
    /// adding `allowAlways` to the shim and the relay left this gate quietly
    /// dropping it. What made that cost a whole diagnosis is the caller's log
    /// line: a nil return is reported as "no open session matches", which
    /// names the one thing that was fine.
    static let acceptedDecisions: Set<String> = ["allow", "deny", "allowAlways"]

    /// Which open session a permission decision addresses, or nil.
    ///
    /// Matches `target(for:in:)`'s session-routing rule exactly — an id from
    /// a previous launch finds nothing rather than falling back to whatever
    /// session happens to be asking right now. This function only answers
    /// "which session"; it says nothing about whether `requestId` is still
    /// outstanding on that session's shim. That check — the one that
    /// actually matters, since a stale id must never be applied to whatever
    /// permission request is outstanding NOW — happens on the `ShimProcess`
    /// side, in `applyPermissionDecision`, which is the only place holding
    /// `pendingPermissionRequestIds`.
    static func decisionTarget(for envelope: DecisionEnvelope,
                                in sessions: [OpenSession]) -> OpenSession? {
        guard envelope.type == "decision",
              !envelope.requestId.isEmpty,
              Self.acceptedDecisions.contains(envelope.decision),
              let id = UUID(uuidString: envelope.sessionId)
        else { return nil }
        return sessions.first { $0.id == id }
    }
}
