import Foundation

/// When a reconnect-after-loss may actually attempt a connection.
///
/// Split out of `RosterPublisher` for the reason `KeepAliveGate` and
/// `MacroPadUnreadTracker` were: the decision is pure, the publisher it lives
/// in needs a live socket to reach, and the mistake this type exists to
/// prevent is invisible — it produces no error, no log, and no crash, just a
/// Mac that stops answering its phone.
///
/// **The whole point is that there is no third case.** The first version of
/// this logic was an early `return` when the floor was not yet clear, which
/// reads as "skip this one" and is really "stop reconnecting": the caller has
/// already dropped the socket and cancelled the ping timer by then, and the
/// only other things that call `connectIfConfigured()` are an observed pane
/// change and a secret change. On an idle Mac — the one this feature exists
/// for — neither happens, so a skipped attempt is a permanent one. Returning
/// an enum with no "do nothing" member is what makes that unrepresentable.
enum RosterReconnectFloor {
    enum Decision: Equatable {
        /// Attempt immediately, and stamp `now` as the new floor.
        case now
        /// Attempt after this many seconds. Always positive.
        case after(TimeInterval)
    }

    /// - Parameters:
    ///   - last: when the previous attempt ran, or nil if there has not been
    ///     one. Nil is `.now`: a first loss must reconnect at once.
    ///   - now: the current time.
    ///   - floor: the minimum spacing between attempts.
    ///
    /// A `last` in the future — a clock stepped backwards by NTP, or a
    /// machine resumed from sleep with a corrected clock — yields `.after`
    /// with a delay no larger than `floor`, rather than a wait of however far
    /// the clock jumped. The elapsed figure is clamped at 0 rather than
    /// treated as "long ago", because a negative elapsed cannot distinguish a
    /// backwards step from a forwards one and the safe direction is to retry
    /// sooner.
    static func decide(last: Date?, now: Date, floor: TimeInterval) -> Decision {
        guard let last else { return .now }
        let elapsed = max(0, now.timeIntervalSince(last))
        guard elapsed < floor else { return .now }
        return .after(floor - elapsed)
    }
}
