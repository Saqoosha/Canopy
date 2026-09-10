import Foundation

/// Prompts typed on the phone that the session could not take yet.
///
/// **Why a queue and not a refusal.** Every gate in
/// `ShimProcess.ineligibilityReasonForReply()` used to end the same way: the
/// relay answered 409, and the phone put the user's words back in the
/// composer with the Mac's own reason beside them. That is correct about the
/// shim and wrong about the person — a prompt sent at a busy session is not a
/// mistake to be corrected, it is the next thing they want the session to do,
/// which is exactly what the Mac's own composer does with one. Holding it
/// until the shim can take it is the same answer, arrived at without making
/// them watch for the turn to end.
///
/// Pure and value-typed on purpose: the ordering rules below are the whole of
/// what can be got wrong here, and they are the half the probe can reach.
/// `ShimProcess` keeps the gate and the clock.
struct PhoneReplyQueue: Equatable {
    /// One waiting prompt.
    ///
    /// `replyId` travels with the text rather than being minted at injection
    /// time: it is the id the PHONE already stored this text under, and it is
    /// what lets the CLI's echo be stamped so the phone draws its local
    /// record and the streamed event as one row (see
    /// `ShimProcess.pendingPhoneReply`). Optional because a phone older than
    /// that mechanism sends none.
    struct Entry: Equatable {
        let replyId: String?
        let text: String
    }

    /// How many prompts may wait at once.
    ///
    /// A ceiling rather than an unbounded list, because the queue's contents
    /// are the one thing here that a lost shim destroys silently: the phone
    /// was told `ok`, and nothing re-delivers. Ten is enough for a person
    /// typing ahead of a long turn and small enough that the loss is
    /// bounded — a runaway sender hits a refusal it can see instead of
    /// building a backlog nobody will ever read.
    static let capacity = 10

    /// Oldest first. The order the user typed them in is the order the
    /// session must receive them in; nothing here reorders or coalesces.
    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    enum AppendResult: Equatable {
        /// Accepted. `depth` is this entry's position counting from 1, so
        /// `depth == 1` means it is next.
        case queued(depth: Int)
        /// Nothing but whitespace. Refused here as well as at the relay and
        /// in `RosterReply.target`, for the reason those two both give: a
        /// wire contract is not a guarantee, and a blank user turn injected
        /// into a real conversation cannot be taken back.
        case empty
        /// At `capacity`. Carries it so the caller's message can name the
        /// number without re-typing it.
        case full(capacity: Int)
    }

    /// Adds a prompt to the back of the queue.
    ///
    /// Trims here rather than trusting the caller, so the text that comes
    /// back out of `takeNext()` is the text that will be injected — the
    /// alternative is two trims that can disagree, and the one downstream of
    /// the emptiness check is the one that would matter.
    mutating func append(text: String, replyId: String?) -> AppendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard entries.count < Self.capacity else { return .full(capacity: Self.capacity) }
        entries.append(Entry(replyId: replyId, text: trimmed))
        return .queued(depth: entries.count)
    }

    /// Removes and returns the oldest prompt, or nil when there is none.
    mutating func takeNext() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Empties the queue, returning how many prompts were dropped.
    ///
    /// The count is the return value rather than something the caller counts
    /// beforehand because the only reason to call this is a teardown, and a
    /// teardown that drops a user's words owes a log line saying how many.
    @discardableResult
    mutating func removeAll() -> Int {
        let dropped = entries.count
        entries.removeAll()
        return dropped
    }
}
