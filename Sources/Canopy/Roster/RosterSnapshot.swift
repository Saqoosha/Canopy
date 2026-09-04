import Foundation

/// What one Mac publishes about itself. A full snapshot every time — the
/// Durable Object replaces rather than merges, so a dropped update can never
/// leave the phone showing a pane that has since closed.
///
/// **Carries no conversation content**, and that is a contract, not an
/// oversight: see the spec's roster section. Adding a field that quotes the
/// transcript reopens a decision that was made deliberately.
struct RosterSnapshot: Codable, Equatable {
    struct Pane: Codable, Equatable {
        let sessionId: String
        /// The CLI's own session id, which survives a Canopy restart while
        /// `sessionId` above does not. Optional because it is backfilled a
        /// moment after spawn — a pane published in that window has none yet,
        /// and the phone falls back to `sessionId` rather than showing nothing.
        let resumeId: String?
        let paneIndex: Int
        let title: String
        let project: String
        let state: String
        let stateSince: Int
        let contextPct: Int
        let model: String
        let messageCount: Int
    }

    let machineId: String
    let displayName: String
    let publishedAt: Int
    let sessionPct: Int
    let weeklyPct: Int
    let panes: [Pane]

    /// The wire name for an activity state.
    ///
    /// Deliberately a `switch` rather than a raw value on `SessionActivity`:
    /// that enum belongs to the sidebar and the MacroPad, and giving it a
    /// wire representation would let a rename there change what the phone
    /// renders. The mapping lives here, where the probe pins it.
    ///
    /// `SessionActivity` carries a seventh case, `.empty`, for a pane slot
    /// with no session behind it (a launcher pane, on the pad only) — it is
    /// never returned by `SessionActivity.of(_:isUnread:)`, so a roster pane
    /// (built only from panes that already hold a session, see
    /// `paneIndexes(in:)`) never carries it. The case still needs a branch to
    /// keep this switch exhaustive against the type it mirrors.
    static func wireState(for activity: SessionActivity) -> String {
        switch activity {
        case .empty: return "empty"
        case .idle: return "idle"
        case .working: return "working"
        case .background: return "background"
        case .asking: return "asking"
        case .unread: return "unread"
        case .error: return "error"
        }
    }

    /// Session id → pane index, for the panes that hold a session.
    ///
    /// A launcher pane is skipped, and the index kept is its position in the
    /// STRIP — so a launcher sitting to the left does not renumber the panes
    /// after it. The phone's row order and Canopy's Cmd+1..9 then agree.
    static func paneIndexes(in panes: [PaneSlot]) -> [OpenSession.ID: Int] {
        var result: [OpenSession.ID: Int] = [:]
        for (index, slot) in panes.enumerated() {
            if case .session(let id) = slot.content { result[id] = index }
        }
        return result
    }
}
