import Foundation

/// Eligibility accounting for the session recap (see `RecapCoordinator`).
///
/// Split out of `ShimProcess` as a pure value type for two reasons. It is
/// directly exercisable from `_SidebarLogicProbe` without spawning a shim —
/// the same treatment `SubagentTracker` already gets, and worth more here
/// because a mistake in this gate is either a silently disabled feature or
/// a repeatedly-billed model call. And collapsing the old `hasRecapped` +
/// `userTurnsSinceRecap` pair into a single `lastRecapTurn` makes the "a
/// recap landed at turn N" fact one field instead of two that had to be
/// written together by adjacency — a future edit can no longer set one and
/// forget the other, which would have blocked recaps on that shim forever.
struct RecapGate: Equatable {
    /// Genuine webview→host prompts seen on this shim. Canopy's own injected
    /// `/recap` never passes through that handler, so it cannot inflate its
    /// own gate.
    private(set) var userTurns = 0

    /// `userTurns` as of the last captured recap; nil when none has landed.
    private(set) var lastRecapTurn: Int?

    mutating func noteUserTurn() {
        userTurns += 1
    }

    mutating func recapLanded() {
        lastRecapTurn = userTurns
    }

    /// Why this gate declines, or nil when it permits a recap.
    ///
    /// `hasHistoricConversation` stands in for "this is a resume with prior
    /// turns". It is deliberately a Bool rather than a count: the only
    /// comparison the gate makes is against 1, and the alternative — parsing
    /// the session JSONL for a prompt count — is what dragged
    /// `NSRegularExpression` onto a background queue (a documented macOS 26
    /// crash) for a number that was then compared to 1.
    ///
    /// `isRemote` only shapes the message. A remote session has no local
    /// JSONL to read at spawn, so it cannot be seeded and stays ineligible
    /// until the user's first prompt; naming that in the reason string keeps
    /// the log honest instead of reporting a bare "no user turns yet" that
    /// reads like a bug.
    func ineligibilityReason(
        hasHistoricConversation: Bool,
        isRemote: Bool = false
    ) -> String? {
        let effectiveTurns = userTurns + (hasHistoricConversation ? 1 : 0)
        guard effectiveTurns >= 1 else {
            return isRemote
                ? "no user turns yet (remote session — history not seeded)"
                : "no user turns yet"
        }
        if let lastRecapTurn, userTurns <= lastRecapTurn {
            return "no new user turns since last recap"
        }
        return nil
    }
}
