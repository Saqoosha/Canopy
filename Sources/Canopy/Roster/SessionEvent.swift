import Foundation

/// One thing that happened in a session, on its way to the phone.
///
/// **Carrying `type` is the only thing that distinguishes this from a roster
/// snapshot on the wire.** A snapshot has no `type` field at all, so both the
/// Durable Object and the phone tell the two apart by that field's presence
/// alone. Remove it and an event is parsed as a malformed snapshot and
/// dropped in silence on both sides.
struct SessionEvent: Codable, Equatable, Sendable {
    /// Always `"event"`. A constant for the reason above.
    let type: String
    /// Minted by Canopy. **Not the same thing as the DO's `seq`** — this one
    /// also rides on the `completed` push, and is what lets the phone tell
    /// that a notification and an event are the same turn. The `seq` is
    /// assigned by the relay and cannot be known here.
    let eventId: String
    let sessionId: String
    let resumeId: String?
    let kind: Kind
    let text: String
    let at: Date

    enum Kind: String, Codable, Sendable {
        case assistant
        case user
        case tool
        case turnStart
        case turnEnd
    }

    /// Upper bound on one event's text, in BYTES. Keeps a single row in the
    /// relay's SQLite from growing without limit.
    static let maxTextBytes = 8 * 1024

    /// Upper bound on a tool's one-line summary, in characters. Separate from
    /// `maxTextBytes` because it is a legibility limit, not a storage one — a
    /// 4000-character command line is not more informative than its first 80.
    static let maxToolSummaryLength = 80

    init(eventId: String, sessionId: String, resumeId: String?, kind: Kind, text: String, at: Date) {
        self.type = "event"
        self.eventId = eventId
        self.sessionId = sessionId
        self.resumeId = resumeId
        self.kind = kind
        self.text = text
        self.at = at
    }

    /// Peel the two envelopes off an unsolicited extension message and return
    /// the CLI frame inside, or nil when this is not one — or when it belongs
    /// to a subagent rather than to this conversation.
    ///
    /// **Measured on device, after the first version read the outermost
    /// `type` and produced nothing for a whole session.** The shape is
    /// `{type:"from-extension", message:{type:"io_message", message:<frame>}}`
    /// — three envelopes deep, which is exactly what `trackWorkingState`
    /// unwraps. A response (as opposed to an unsolicited message) is NOT
    /// wrapped, and is not a stream frame either, so it correctly falls out
    /// here.
    static func ioFrame(in message: [String: Any]) -> [String: Any]? {
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any],
              nested["type"] as? String == "io_message",
              let frame = nested["message"] as? [String: Any]
        else { return nil }
        // **A subagent's turns are not this conversation.** The CLI re-emits
        // them as ordinary `assistant` / `user` frames carrying a
        // `parent_tool_use_id` — the property `ShimProcess`'s own
        // `isMainConversationMessage` was written against. Without this, one
        // Agent call streams its dozens of tool lines and its assistant text
        // into a 200-event ring buffer as if they were the main session, and
        // the Agent's own prompt arrives drawn as something the human typed.
        // The turn boundaries were withdrawn for costing a fifth of that
        // buffer; a subagent costs far more.
        let parent = frame["parent_tool_use_id"]
        guard parent == nil || parent is NSNull else { return nil }
        return frame
    }

    /// Convenience over `events(fromFrame:…)` that unwraps first. Callers on
    /// the io_message path hand in the whole envelope.
    /// - Parameter stampUser: given a `user` turn's text, the id that turn
    ///   should carry instead of a fresh one, or nil. This is how a reply
    ///   typed on the PHONE gets the id the phone already stored it under:
    ///   the phone mints `replyId`, the Mac injects the text and remembers
    ///   the pair, and the CLI's echo of that text comes back through here
    ///   carrying the phone's own id — so the phone can tell its local
    ///   "sent" record and the streamed event are one thing and draw one.
    ///   Matched on text rather than on the injected frame's `uuid` because
    ///   whether the echo preserves that field is unmeasured; text is what
    ///   `isKeepAliveEcho` and `isRecapEcho` already match on.
    static func events(from message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String,
                       stampUser: ((String) -> String?)? = nil) -> [SessionEvent] {
        guard let frame = ioFrame(in: message) else { return [] }
        return events(fromFrame: frame, sessionId: sessionId, resumeId: resumeId,
                      at: at, nextId: nextId, stampUser: stampUser)
    }

    /// Turn one CLI frame into zero or more events. Pure.
    ///
    /// **Most `user` frames are tool results, not conversation.** A frame
    /// whose content holds any `tool_result` block is dropped. Losing that
    /// filter fills the phone's conversation with tool output, which is the
    /// single most likely regression in this file.
    ///
    /// A bulk history replay never reaches here: the CLI delivers it as ONE
    /// message carrying a `response.messages` array, and `ioFrame` only reads
    /// the top-level `type`. Measured on CLI 2.1.258 with Canopy's own flags
    /// — a `--resume` does not re-emit historical `assistant` frames
    /// individually.
    static func events(fromFrame message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String,
                       stampUser: ((String) -> String?)? = nil) -> [SessionEvent] {
        func make(_ kind: Kind, _ text: String, id: String? = nil) -> SessionEvent? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionEvent(eventId: id ?? nextId(), sessionId: sessionId, resumeId: resumeId,
                                kind: kind, text: capped(trimmed), at: at)
        }

        /// The text blocks of a `message.content`, whichever of its two wire
        /// shapes it takes. **A `user` echo can carry `content` as a plain
        /// string**, not only as an array of blocks — both existing echo
        /// matchers accept both forms, and the first version here read only
        /// the array, which would have dropped every string-form turn.
        func joinedText(of content: Any?) -> String {
            if let blocks = content as? [[String: Any]] {
                return blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            }
            return content as? String ?? ""
        }

        switch message["type"] as? String {
        case "assistant":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var out: [SessionEvent] = []
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if let event = make(.assistant, text) { out.append(event) }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String,
                      let event = make(.tool, toolLabel(name: name, input: block["input"] as? [String: Any]))
                else { continue }
                out.append(event)
            }
            return out

        case "user":
            let content = (message["message"] as? [String: Any])?["content"]
            if let blocks = content as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return []
            }
            let text = joinedText(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
            return [make(.user, text, id: stampUser?(text))].compactMap { $0 }

        // `system/init` and `result` — the turn boundaries — are deliberately
        // NOT emitted. They were, at first: two events per turn into a
        // 200-event ring buffer the phone never drew (`SessionEventBlock`
        // renders them as nothing), so roughly a fifth of a session's recent
        // history was spent on rows nobody could see. "Is it still working"
        // is answered by the roster's state dot, not by an event. The enum
        // cases stay so an older relay's stored rows still decode.
        default:
            return []
        }
    }

    /// The display label for one tool call.
    ///
    /// **The default is the name alone, and only the tools listed here get a
    /// summary.** Never invert this into "show `input` unless the tool is
    /// dangerous": every tool added upstream would then start sending its
    /// arguments through the relay, with nobody deciding that it should.
    /// Removing a case from this switch is always safe; adding one is the
    /// only direction that needs a judgement about what may leave the Mac.
    ///
    /// `Read`/`Edit`/`Write` deliberately send the file's LAST PATH COMPONENT
    /// and not the path: the name says what is being worked on, while the
    /// directories describe the machine itself.
    static func toolLabel(name: String, input: [String: Any]?) -> String {
        func short(_ value: String?) -> String? {
            guard let value, let line = value.split(separator: "\n").first else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.count > maxToolSummaryLength
                ? String(trimmed.prefix(maxToolSummaryLength)) + "…"
                : trimmed
        }
        let summary: String?
        switch name {
        case "Bash":
            summary = short(input?["command"] as? String)
        case "Read", "Edit", "Write":
            summary = short((input?["file_path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            })
        case "Glob", "Grep":
            summary = short(input?["pattern"] as? String)
        case "Task", "Agent":
            summary = short(input?["description"] as? String)
        default:
            summary = nil
        }
        guard let summary else { return name }
        return "\(name): \(summary)"
    }

    /// Cut to `maxTextBytes` measured in UTF-8 BYTES, not characters. What
    /// reaches the relay is bytes, and one Japanese character is three of
    /// them — a character limit is not a limit on what is stored. Trimming
    /// whole `Character`s means a surrogate pair is never split.
    private static func capped(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var out = text
        while out.utf8.count > maxTextBytes - 3, !out.isEmpty {
            out.removeLast()
        }
        return out + "…"
    }
}
