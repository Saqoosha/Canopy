import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlEvents")

/// One thing a `listen` client can wait for. Recorded by the daemon whether or
/// not anyone is listening, so a client that reconnects with its cursor still
/// gets what happened in between.
nonisolated struct ControlEvent: Equatable, Sendable, Codable {
    enum Kind: String, CaseIterable, Sendable, Codable {
        /// A main-conversation turn ended (`result`), whoever started it.
        case turnDone = "turn_done"
        /// A tool permission request arrived.
        case permission
        /// An AskUserQuestion arrived.
        case asking
        /// A turn ended without a `result`: its CLI was stopped, died, or the daemon exited.
        /// Never resent by the daemon.
        case turnInterrupted = "turn_interrupted"
        case sessionOpened = "session_opened"
        case sessionClosed = "session_closed"
        /// Not recorded: what `listen` returns when the cursor cannot be
        /// continued (a daemon start without a saved log, log wrapped, or a cursor ahead of the log).
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
    /// On `turn_done`: what the person sent to start the turn, wherever they typed it.
    var prompt: String?
    var promptTruncated = false
    /// On `turn_done`: whether the turn ended on an error. Nil on every other kind.
    var isError: Bool?
    /// On a failed `turn_done`: `TurnFailure.kind` and the CLI's own code for it.
    var errorKind: String?
    var errorCode: String?
    /// On `session_closed`: why it left the open list (`CloseReason`). On
    /// `turn_interrupted`: `InterruptReason`. On `session_opened`: `restored`
    /// when the daemon brought it back after a restart.
    var reason: String?
    /// On `session_closed` with `daemon_restart`: the next daemon means to reopen it under the
    /// same key; a `restore_failed` close follows if it cannot.
    var resumes: Bool?

    /// Why a turn ended without a `result`.
    enum InterruptReason: String, Sendable {
        /// Its CLI was stopped on purpose: `stop_session`, `restart_session`, an account switch.
        case stopped
        /// Its CLI exited on its own.
        case crashed
        case daemonRestart = "daemon_restart"
    }

    /// Why a session left the daemon's open list.
    enum CloseReason: String, Sendable {
        /// `stop_session` (the GUI's Stop goes through it too).
        case stopped
        /// The reaper stopped it: no client, idle past `SessionReaper.defaultIdleLimit`.
        case reaped
        /// The daemon is shutting down (an update, Restart now, launchd, SIGTERM).
        case daemonRestart = "daemon_restart"
        /// Reported by a restarted daemon for a session it said it would reopen and could not.
        case restoreFailed = "restore_failed"
        /// Removed by a path that did not say why.
        case other
    }

    /// How a turn failed, read off its `result` frame and the turn's last
    /// main-conversation `assistant` frame's `error`. The result's `subtype`
    /// stays `success` on an API error (measured, CLI 2.1.287), so the
    /// assistant frame is what names the cause there.
    struct TurnFailure: Equatable, Sendable {
        var kind: String
        var code: String?

        /// Nil when the turn did not fail.
        static func of(result: [String: Any], assistantError: String?) -> TurnFailure? {
            let subtype = result["subtype"] as? String
            let failedSubtype = subtype.map { $0 != "success" } ?? false
            guard result["is_error"] as? Bool == true || failedSubtype else { return nil }
            if failedSubtype, let subtype {
                switch subtype {
                case "error_max_turns": return TurnFailure(kind: "max_turns", code: subtype)
                case "error_max_budget_usd": return TurnFailure(kind: "budget", code: subtype)
                case "error_during_execution": return TurnFailure(kind: "execution", code: subtype)
                default: break
                }
            }
            let code = assistantError ?? (failedSubtype ? subtype : nil)
            switch code {
            case "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required":
                return TurnFailure(kind: "auth", code: code)
            case "cloud_credential_error":
                return TurnFailure(kind: "auth", code: code)
            case "rate_limit": return TurnFailure(kind: "rate_limit", code: code)
            case "billing_error": return TurnFailure(kind: "billing", code: code)
            case "overloaded": return TurnFailure(kind: "overloaded", code: code)
            case "server_error":
                // No HTTP status: no answer came back (measured: connection refused).
                let status = result["api_error_status"] as? Int
                return TurnFailure(kind: status == nil ? "network" : "server", code: code)
            default:
                return TurnFailure(kind: "other", code: code)
            }
        }
    }

    var wire: [String: Any] {
        // A gap names no session and no event; its `state` slot carries the reason.
        if kind == .gap {
            return ["event": kind.rawValue, "at": at.timeIntervalSince1970, "reason": state ?? ""]
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
        if let prompt {
            out["prompt"] = prompt
            if promptTruncated { out["promptTruncated"] = true }
        }
        if let isError { out["isError"] = isError }
        if let errorKind { out["errorKind"] = errorKind }
        if let errorCode { out["errorCode"] = errorCode }
        if let reason { out["reason"] = reason }
        if let resumes { out["resumes"] = resumes }
        return out
    }

    /// Who a reply says it is for, read off its first non-blank line:
    /// `Written for: X` or `宛先: X`. Markdown decoration (`#`, `>`, `*`, `_`)
    /// around the line is ignored. Nil when the reply names no one this way.
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
        for prefix in ["written for:", "宛先:", "宛先："] where lower.hasPrefix(prefix) {
            return clean(stripped.dropFirst(prefix.count))
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

    /// Longest `text` a recorded event keeps, in UTF-8 bytes.
    static let textMaxBytes = 32_000
}

/// Position in the event log. The epoch changes when a daemon starts without a
/// saved log (after a crash), so a cursor from before is recognised as stale
/// instead of silently meaning a different event.
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
        // A JSON null is the same as leaving the param out.
        let params = params.filter { !($0.value is NSNull) }
        if params["addressedTo"] != nil, !(params["addressedTo"] is String) {
            return .failure(.init("addressedTo must be a string"))
        }
        if params["since"] != nil, !(params["since"] is String) {
            return .failure(.init("since must be a cursor string"))
        }
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
        if to != nil, !kinds.contains("addressed") {
            return .failure(.init("addressedTo needs events to include addressed"))
        }
        var since: ControlEventCursor?
        if let raw = params["since"] as? String, !raw.isEmpty {
            guard let cursor = ControlEventCursor(wire: raw) else {
                return .failure(.init("since is not a cursor"))
            }
            since = cursor
        }
        var timeout = defaultTimeout
        if let raw = params["timeout"] {
            // `is Bool` is true for a JSON 0 or 1 too; only the CF type tells `true` from `1`.
            let isBool = CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID()
            guard !isBool, let number = (raw as? NSNumber)?.doubleValue, number.isFinite, number > 0 else {
                return .failure(.init("timeout must be a positive number of seconds"))
            }
            timeout = max(number, 1)
        }
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
        // Seqs are contiguous in the ring, so the first event after the cursor is at a known index.
        let start = min(max(since.seq - oldest + 1, 0), events.count)
        for event in events[start...] where filter.matches(event) {
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

    private init() {}

    /// Kept across a clean restart (`save` / `restoreSaved`), so a cursor from
    /// before it continues; a fresh one after a crash.
    private(set) var epoch = String(UUID().uuidString.lowercased().prefix(8))
    private(set) var events: [ControlEvent] = []
    private(set) var latestSeq = 0
    private var waiters: [UUID: () -> Void] = [:]

    /// What `save` writes: the whole ring, its epoch and last seq.
    struct Saved: Codable, Equatable {
        var epoch: String
        var latestSeq: Int
        var events: [ControlEvent]
    }

    static var savedFileURL: URL {
        let bundleId = Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Canopy", isDirectory: true)
            .appendingPathComponent("daemon-events-\(bundleId).json")
    }

    /// At shutdown. Owner-only: events hold prompts and replies.
    func save(to url: URL = savedFileURL) {
        do {
            let data = try JSONEncoder().encode(Saved(epoch: epoch, latestSeq: latestSeq, events: events))
            // Created 0600 and renamed into place: never readable by others, never half written.
            let tmp = url.appendingPathExtension("tmp-\(getpid())")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(tmp.path, url.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: tmp)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            logger.notice("[control] saved \(self.events.count, privacy: .public) event(s) at \(self.epoch, privacy: .public).\(self.latestSeq, privacy: .public)")
        } catch {
            logger.error("[control] could not save events: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// At launch, before anything is recorded. Read and delete, so a log that
    /// crashes the daemon is not replayed; an unreadable one starts a new epoch.
    func restoreSaved(from url: URL = savedFileURL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard latestSeq == 0 else {
            logger.error("[control] saved events not restored: events were recorded first")
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("[control] saved events not restored: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            guard adopt(try JSONDecoder().decode(Saved.self, from: data)) else {
                logger.error("[control] saved events inconsistent; starting epoch \(self.epoch, privacy: .public)")
                return
            }
        } catch {
            logger.error("[control] saved events unreadable (\(error.localizedDescription, privacy: .public)); starting epoch \(self.epoch, privacy: .public)")
            return
        }
        logger.notice("[control] continued epoch \(self.epoch, privacy: .public) at seq \(self.latestSeq, privacy: .public)")
    }

    /// False when `saved` breaks what `scan` relies on: seqs contiguous, the last one `latestSeq`.
    @discardableResult
    func adopt(_ saved: Saved) -> Bool {
        let seqs = saved.events.map(\.seq)
        guard !saved.epoch.isEmpty, saved.latestSeq >= 0,
              zip(seqs, seqs.dropFirst()).allSatisfy({ $1 == $0 + 1 }),
              (seqs.last ?? saved.latestSeq) == saved.latestSeq else { return false }
        epoch = saved.epoch
        latestSeq = saved.latestSeq
        events = Array(saved.events.suffix(Self.capacity))
        return true
    }

    func record(_ kind: ControlEvent.Kind, session: OpenSession?, state: String? = nil, replyId: String? = nil,
                requestId: String? = nil, toolName: String? = nil, text: String? = nil, addressedTo: String? = nil,
                prompt: String? = nil, failure: ControlEvent.TurnFailure? = nil, reason: String? = nil,
                textMaxBytes: Int = ControlEvent.textMaxBytes) {
        guard let session else {
            logger.notice("[control] \(kind.rawValue, privacy: .public) not recorded: no bound session")
            return
        }
        record(kind, key: session.id.uuidString, sessionId: session.resumeId, title: session.title,
               state: state, replyId: replyId, requestId: requestId, toolName: toolName, text: text,
               addressedTo: addressedTo, prompt: prompt, failure: failure, reason: reason, textMaxBytes: textMaxBytes)
    }

    func record(_ kind: ControlEvent.Kind, key: String, sessionId: String, title: String, state: String? = nil,
                replyId: String? = nil, requestId: String? = nil, toolName: String? = nil, text: String? = nil,
                addressedTo: String? = nil, prompt: String? = nil, failure: ControlEvent.TurnFailure? = nil,
                reason: String? = nil, resumes: Bool? = nil, textMaxBytes: Int = ControlEvent.textMaxBytes) {
        latestSeq += 1
        var event = ControlEvent(seq: latestSeq, kind: kind, key: key, sessionId: sessionId, title: title, at: Date(),
                                 state: state, replyId: replyId, requestId: requestId, toolName: toolName,
                                 addressedTo: addressedTo)
        if kind == .turnDone {
            event.isError = failure != nil
            event.errorKind = failure?.kind
            event.errorCode = failure?.code
        }
        event.reason = reason
        event.resumes = resumes
        if let prompt {
            event.prompt = ShimProcess.truncatedNotificationBody(prompt, maxBytes: ControlEvent.textMaxBytes)
            event.promptTruncated = prompt.utf8.count > ControlEvent.textMaxBytes
        }
        if let text {
            event.text = ShimProcess.truncatedNotificationBody(text, maxBytes: textMaxBytes)
            event.textTruncated = text.utf8.count > textMaxBytes
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
    /// Set just before a removal so `observe` can say why; consumed there.
    private var closeReasons: [UUID: ControlEvent.CloseReason] = [:]

    /// Names the reason for the next removal of `id` from the open list.
    func noteClosing(_ id: UUID, reason: ControlEvent.CloseReason) {
        guard trackedStore != nil else { return }
        closeReasons[id] = reason
    }

    /// `session_closed` for every open session, now: at shutdown nothing
    /// removes them, and the process exits before `observe` would run. A turn
    /// still running is reported as `turn_interrupted` first. `resuming` holds
    /// the keys the next daemon will reopen (`DaemonHeldSessions`).
    func recordShutdown(resuming: Set<String>) {
        guard let store = trackedStore else { return }
        // Opens and closes still queued for `observe` are recorded first, with their reasons.
        observe()
        for session in store.openSessions {
            session.shim?.recordTurnInterrupted(.daemonRestart)
            let key = session.id.uuidString
            record(.sessionClosed, key: key, sessionId: session.resumeId, title: session.title,
                   reason: ControlEvent.CloseReason.daemonRestart.rawValue, resumes: resuming.contains(key))
        }
        known = [:]
        trackedStore = nil
    }

    /// Sessions reopened after a restart; their `session_opened` says `restored`.
    private var restoredIds: Set<UUID> = []

    func noteRestored(_ id: UUID) { restoredIds.insert(id) }

    func forgetRestored(_ id: UUID) { restoredIds.remove(id) }

    /// A session the previous daemon said `resumes` for and this one could not bring back.
    func recordRestoreFailed(key: String, sessionId: String, title: String) {
        record(.sessionClosed, key: key, sessionId: sessionId, title: title,
               reason: ControlEvent.CloseReason.restoreFailed.rawValue)
    }

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
        let closed = known.filter { now[$0.key] == nil }.sorted { $0.value.key < $1.value.key }
        known = now
        for session in opened {
            record(.sessionOpened, key: session.id.uuidString, sessionId: session.resumeId, title: session.title,
                   reason: restoredIds.remove(session.id) != nil ? "restored" : nil)
        }
        for (id, gone) in closed {
            record(.sessionClosed, key: gone.key, sessionId: gone.sessionId, title: gone.title,
                   reason: (closeReasons.removeValue(forKey: id) ?? .other).rawValue)
        }
        // Callers note a reason and remove in one main-actor turn, so by now every noted
        // removal has been seen; one that did not happen must not label a later one.
        closeReasons = [:]
    }
}
