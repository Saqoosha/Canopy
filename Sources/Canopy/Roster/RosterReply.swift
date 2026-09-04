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
}
