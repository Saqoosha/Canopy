import Foundation

/// One thing a `listen` client can wait for. Recorded by the daemon whether or
/// not anyone is listening, so a client that reconnects with its cursor still
/// gets what happened in between.
nonisolated struct ControlEvent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// A main-conversation turn ended (`result`), whoever started it.
        case turnDone = "turn_done"
        /// A tool permission request arrived.
        case permission
        /// An AskUserQuestion arrived.
        case asking
        case sessionOpened = "session_opened"
        case sessionClosed = "session_closed"
        /// Not recorded: what `listen` returns when events between the
        /// cursor and now were lost (daemon restart, or the log wrapped).
        case gap
    }

    var seq: Int
    var kind: Kind
    var key: String
    var sessionId: String
    var title: String
    var at: Date
    var state: String?
    var replyId: String?
    var requestId: String?
    var toolName: String?
    var text: String?
    var textTruncated = false
    var addressedTo: String?

    var wire: [String: Any] {
        // A gap names no session; its `state` slot carries the reason.
        if kind == .gap {
            return ["event": kind.rawValue, "seq": seq, "at": at.timeIntervalSince1970, "reason": state ?? ""]
        }
        var out: [String: Any] = [
            "event": kind.rawValue, "seq": seq, "key": key, "sessionId": sessionId,
            "title": title, "at": at.timeIntervalSince1970,
        ]
        if let state { out["state"] = state }
        if let replyId { out["replyId"] = replyId }
        if let requestId { out["requestId"] = requestId }
        if let toolName { out["toolName"] = toolName }
        if let text {
            out["text"] = text
            if textTruncated { out["textTruncated"] = true }
        }
        if let addressedTo { out["addressedTo"] = addressedTo }
        return out
    }

    /// Who a reply says it is for, read off its first non-blank line:
    /// `Written for: X`, `To: X`, `宛先: X`, or a short `X へ` / `X 宛`.
    /// Markdown decoration (`#`, `>`, `*`, `_`) around the line is ignored.
    /// Nil when the reply names no one this way.
    static func addressee(of text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let decoration = CharacterSet(charactersIn: "#>*_ \t")
        let stripped = line.trimmingCharacters(in: decoration)
        func clean(_ name: Substring) -> String? {
            let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: ".。:：*_ \t"))
            return trimmed.isEmpty ? nil : trimmed
        }
        let lower = stripped.lowercased()
        for prefix in ["written for:", "to:", "宛先:", "宛先："] where lower.hasPrefix(prefix) {
            return clean(stripped.dropFirst(prefix.count))
        }
        // A greeting line, not a sentence that happens to end in へ.
        guard stripped.count <= 40 else { return nil }
        for suffix in ["へ", "宛", "宛て"] {
            var body = Substring(stripped)
            while let last = body.last, "。.:：".contains(last) { body = body.dropLast() }
            if body.hasSuffix(suffix) { return clean(body.dropLast(suffix.count)) }
        }
        return nil
    }

    /// What a `turn_done` reports. The CLI's `result` holds only the turn's
    /// LAST text block, and a reply addressed to someone is often followed by
    /// more text (a Stop hook making the model continue, measured), so the
    /// addressee is looked for in every main-conversation text block. When one
    /// names a reader, `text` runs from that block to the end of the turn.
    static func turnReply(blocks: [String], result: String) -> (text: String, addressedTo: String?) {
        for (index, block) in blocks.enumerated() {
            if let to = addressee(of: block) {
                return (blocks[index...].joined(separator: "\n\n"), to)
            }
        }
        return (result, addressee(of: result))
    }

    /// Folds one `assistant` frame's text blocks into the turn so far. The CLI
    /// may send a message's blocks one frame at a time or cumulatively under
    /// one message id; a cumulative frame replaces what that id already gave.
    static func appendingTurnText(_ turn: [(id: String, texts: [String])], id: String,
                                  texts: [String]) -> [(id: String, texts: [String])] {
        var turn = turn
        if let last = turn.last, last.id == id {
            let merged = texts.starts(with: last.texts) ? texts : last.texts + texts
            turn[turn.count - 1] = (id, merged)
        } else if !texts.isEmpty {
            turn.append((id, texts))
        }
        return turn
    }

    /// Longest `text` a recorded turn keeps, in UTF-8 bytes.
    static let textMaxBytes = 32_000
}

/// Position in the event log. The epoch changes every daemon launch, so a
/// cursor from before a restart is recognised as stale instead of silently
/// meaning a different event.
nonisolated struct ControlEventCursor: Equatable, Sendable {
    var epoch: String
    var seq: Int

    var wire: String { "\(epoch).\(seq)" }

    init(epoch: String, seq: Int) {
        self.epoch = epoch
        self.seq = seq
    }

    init?(wire: String) {
        guard let dot = wire.lastIndex(of: "."),
              let seq = Int(wire[wire.index(after: dot)...]), seq >= 0 else { return nil }
        let epoch = String(wire[..<dot])
        guard !epoch.isEmpty else { return nil }
        self.init(epoch: epoch, seq: seq)
    }
}

/// What a `listen` request asks for.
nonisolated struct ControlListenFilter: Equatable, Sendable {
    /// Requested names; `addressed` is a turn_done whose reply names someone.
    var kinds: Set<String>
    var key: String?
    var sessionId: String?
    var addressedTo: String?

    static let kindNames: Set<String> = Set(ControlEvent.Kind.allCases.filter { $0 != .gap }.map(\.rawValue)).union(["addressed"])

    func matches(_ event: ControlEvent) -> Bool {
        if event.kind == .gap { return true }
        if let key, event.key != key { return false }
        if let sessionId, event.sessionId != sessionId { return false }
        if kinds.contains(event.kind.rawValue) { return true }
        guard kinds.contains("addressed"), event.kind == .turnDone, let to = event.addressedTo else { return false }
        guard let wanted = addressedTo else { return true }
        return to.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

nonisolated struct ControlListenParams: Equatable, Sendable {
    var filter: ControlListenFilter
    /// Nil: only events after this request arrives.
    var since: ControlEventCursor?
    var timeout: TimeInterval

    static let defaultTimeout: TimeInterval = 300
    static let maxTimeout: TimeInterval = 3600

    static func parse(_ params: [String: Any]) -> Result<ControlListenParams, ControlProtocol.ControlError> {
        var kinds = ControlListenFilter.kindNames.subtracting(["addressed"])
        if let raw = params["events"] {
            guard let list = raw as? [String], !list.isEmpty else {
                return .failure(.init("events must be a non-empty array of strings"))
            }
            let unknown = list.filter { !ControlListenFilter.kindNames.contains($0) }
            guard unknown.isEmpty else {
                return .failure(.init("unknown event: \(unknown.joined(separator: ", "))"))
            }
            kinds = Set(list)
        }
        let addressedTo = (params["addressedTo"] as? String)?.trimmingCharacters(in: .whitespaces)
        let to = addressedTo?.isEmpty == false ? addressedTo : nil
        // Naming a recipient without naming events means "replies to that recipient".
        if to != nil, params["events"] == nil { kinds = ["addressed"] }
        var since: ControlEventCursor?
        if let raw = params["since"] as? String, !raw.isEmpty {
            guard let cursor = ControlEventCursor(wire: raw) else {
                return .failure(.init("since is not a cursor"))
            }
            since = cursor
        }
        var timeout = defaultTimeout
        if let raw = params["timeout"] as? Double { timeout = raw } else if let raw = params["timeout"] as? Int { timeout = Double(raw) }
        guard timeout > 0 else { return .failure(.init("timeout must be positive")) }
        var key: String?
        var sessionId: String?
        for ref in ControlProtocol.sessionRefs(params) {
            switch ref {
            case .key(let value): key = value
            case .resumeId(let value): sessionId = value
            }
        }
        return .success(ControlListenParams(
            filter: ControlListenFilter(kinds: kinds, key: key, sessionId: sessionId, addressedTo: to),
            since: since, timeout: min(timeout, maxTimeout)))
    }
}

/// The answer to one look at the log.
nonisolated enum ControlListenScan: Equatable, Sendable {
    /// Return this event; the client's next cursor is `cursor`.
    case event(ControlEvent, cursor: ControlEventCursor)
    /// Nothing yet; resume scanning after `cursor`.
    case wait(cursor: ControlEventCursor)

    /// `events` ascending by seq; `latestSeq` is the last seq ever assigned
    /// in this epoch (0 before the first).
    static func scan(events: [ControlEvent], epoch: String, latestSeq: Int, since: ControlEventCursor?,
                     filter: ControlListenFilter, now: Date) -> ControlListenScan {
        guard let since else { return .wait(cursor: ControlEventCursor(epoch: epoch, seq: latestSeq)) }
        func gap(_ reason: String, resumeAt seq: Int) -> ControlListenScan {
            let event = ControlEvent(seq: seq, kind: .gap, key: "", sessionId: "", title: "", at: now, state: reason)
            return .event(event, cursor: ControlEventCursor(epoch: epoch, seq: seq))
        }
        let oldest = events.first?.seq ?? latestSeq + 1
        if since.epoch != epoch {
            // Everything this daemon still holds is newer than the old cursor.
            return gap("daemon_restarted", resumeAt: oldest - 1)
        }
        if since.seq > latestSeq { return gap("unknown_cursor", resumeAt: latestSeq) }
        if since.seq < oldest - 1 { return gap("overflow", resumeAt: oldest - 1) }
        for event in events where event.seq > since.seq && filter.matches(event) {
            return .event(event, cursor: ControlEventCursor(epoch: epoch, seq: event.seq))
        }
        return .wait(cursor: ControlEventCursor(epoch: epoch, seq: latestSeq))
    }
}

/// The daemon's event log: a bounded ring every shim appends to, plus the
/// waiters `listen` parks on it.
@MainActor
final class ControlEventLog {
    static let shared = ControlEventLog()
    static let capacity = 1000

    let epoch = String(UUID().uuidString.lowercased().prefix(8))
    private(set) var events: [ControlEvent] = []
    private(set) var latestSeq = 0
    private var waiters: [UUID: () -> Void] = [:]

    func record(_ kind: ControlEvent.Kind, session: OpenSession?, state: String? = nil, replyId: String? = nil,
                requestId: String? = nil, toolName: String? = nil, text: String? = nil, addressedTo: String? = nil) {
        guard let session else { return }
        record(kind, key: session.id.uuidString, sessionId: session.resumeId, title: session.title,
               state: state, replyId: replyId, requestId: requestId, toolName: toolName, text: text,
               addressedTo: addressedTo)
    }

    func record(_ kind: ControlEvent.Kind, key: String, sessionId: String, title: String, state: String? = nil,
                replyId: String? = nil, requestId: String? = nil, toolName: String? = nil, text: String? = nil,
                addressedTo: String? = nil) {
        latestSeq += 1
        var event = ControlEvent(seq: latestSeq, kind: kind, key: key, sessionId: sessionId, title: title, at: Date(),
                                 state: state, replyId: replyId, requestId: requestId, toolName: toolName,
                                 addressedTo: addressedTo)
        if let text {
            event.text = ShimProcess.truncatedNotificationBody(text, maxBytes: ControlEvent.textMaxBytes)
            event.textTruncated = text.utf8.count > ControlEvent.textMaxBytes
        }
        events.append(event)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        for waiter in Array(waiters.values) { waiter() }
    }

    func scan(since: ControlEventCursor?, filter: ControlListenFilter) -> ControlListenScan {
        ControlListenScan.scan(events: events, epoch: epoch, latestSeq: latestSeq, since: since, filter: filter, now: Date())
    }

    /// Called after every append until removed.
    func addWaiter(_ waiter: @escaping () -> Void) -> UUID {
        let id = UUID()
        waiters[id] = waiter
        return id
    }

    func removeWaiter(_ id: UUID) { waiters.removeValue(forKey: id) }

    // MARK: - Session open / close

    private struct Known: Equatable {
        var key: String
        var sessionId: String
        var title: String
    }

    private weak var trackedStore: SessionStore?
    private var known: [UUID: Known] = [:]

    /// Records `session_opened` / `session_closed` for `store`'s open list.
    /// Idempotent; sessions already open when tracking starts are not reported.
    func track(_ store: SessionStore) {
        guard trackedStore == nil else { return }
        trackedStore = store
        known = Self.snapshot(store)
        observe()
    }

    private static func snapshot(_ store: SessionStore) -> [UUID: Known] {
        Dictionary(uniqueKeysWithValues: store.openSessions.map {
            ($0.id, Known(key: $0.id.uuidString, sessionId: $0.resumeId, title: $0.title))
        })
    }

    private func observe() {
        guard let store = trackedStore else { return }
        let now = withObservationTracking {
            Self.snapshot(store)
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { ControlEventLog.shared.observe() } }
        }
        let opened = store.openSessions.filter { known[$0.id] == nil }
        let closed = known.filter { now[$0.key] == nil }.values.sorted { $0.key < $1.key }
        known = now
        for session in opened {
            record(.sessionOpened, key: session.id.uuidString, sessionId: session.resumeId, title: session.title)
        }
        for gone in closed {
            record(.sessionClosed, key: gone.key, sessionId: gone.sessionId, title: gone.title)
        }
    }
}
