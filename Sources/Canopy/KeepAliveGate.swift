import Foundation

/// Eligibility accounting for the prompt-cache keep-alive (see
/// `KeepAliveCoordinator`).
///
/// A pure value type for the same two reasons `RecapGate` is one: it is
/// exercisable from `_SidebarLogicProbe` without spawning a shim, and a
/// mistake here is billed. The failure modes are asymmetric, which is why
/// the gate is written as "why not" rather than "may I" — declining too
/// often costs one cache miss the user would have paid anyway, while
/// permitting too often bills a model call per session per interval,
/// forever, on a machine nobody is sitting at.
struct KeepAliveGate: Equatable {
    /// How long after the last API activity a refresh is worth buying.
    ///
    /// The window being defended is the CLI's 1-hour prompt-cache TTL
    /// (`ttl:"1h", reason:"subscriber"`, read out of the bundled CLI
    /// 2.1.258). Five minutes of margin covers the gap between "the last
    /// request in a turn went out" and "the turn's `result` arrived", which
    /// is what `noteActivity` actually stamps, plus one tick of the
    /// coordinator's own cadence.
    ///
    /// Anthropic's pricing table bills this column as "Cache hits **and
    /// refreshes**" — a hit is what re-arms the TTL, so a single small turn
    /// buys another full window. That is the whole mechanism; if hits ever
    /// stop refreshing, this feature becomes pure cost and should be
    /// deleted rather than retuned.
    static let defaultInterval: TimeInterval = 55 * 60

    /// Skip the refresh once the 5-hour window is this full.
    ///
    /// Not a cost gate — the money case is overwhelming (a refresh is a
    /// small fraction of the cache write it avoids; see
    /// `KeepAliveCoordinator` for the ratio and its model dependence). This
    /// defends the
    /// resource the user cannot buy back: quota they will want when they
    /// return. Spending the last fifth of a session window on turns nobody
    /// reads is the one way this feature can leave someone worse off than
    /// not having it.
    static let rateLimitCeiling = 80

    /// The tag `promptText` opens with. Split out so the prompt-history
    /// skip list can match a refresh by prefix without re-typing the tag,
    /// and so `promptText` cannot be reworded out from under it.
    static let promptPrefix = "[Canopy keep-alive]"

    /// The text injected as the keep-alive turn, and the exact string the
    /// echo swallow matches on.
    ///
    /// One constant because the two uses must never drift: a mismatch does
    /// not fail loudly, it leaves the prompt visible in the transcript
    /// while the reply is still swallowed, i.e. a bubble with no answer.
    ///
    /// It is written to be legible to two readers. The model, so the reply
    /// is one token and no tool runs — a request, not a constraint: the turn
    /// runs in-session with the full toolset, and this project has already
    /// measured that a counter-instruction in a user turn cannot beat a
    /// persona in the system prompt (see the title-generation learnings).
    /// And a future session reading the JSONL, since unlike the recap fork
    /// this turn is a REAL one and stays in the conversation context
    /// permanently.
    ///
    /// It is NOT written for a human scrolling the transcript — an earlier
    /// revision claimed that, which contradicted the swallow and left the
    /// intent genuinely ambiguous. These turns are hidden live AND on replay
    /// (`ShimProcess.strippingKeepAliveArtifacts`).
    static let promptText = "\(promptPrefix) Prompt-cache refresh, no action needed. Do not use any tool and do not think about this. Reply with exactly: OK"

    /// When the session last STARTED talking to the API, as far as this
    /// shim can tell — stamped at user submission and at a refresh's
    /// injection, never at a turn's end. A cache entry's lifetime runs from
    /// the start of the request that writes or reads it and generation time
    /// counts against it, so a turn's end is minutes too late an estimate on
    /// exactly the long agentic turns this feature is for. The reasoning is
    /// on `ShimProcess.noteApiActivity`.
    private(set) var lastActivityAt: Date?

    /// Refreshes ATTEMPTED on this shim — `requestKeepAlive` stamps it at
    /// injection, and a send is fire-and-forget, so it counts tries rather
    /// than confirmed refreshes. Used in the log line and pinned by the
    /// probe; a keep-alive that fires forever is the intended behaviour, so
    /// there is deliberately no cap here for it to feed.
    private(set) var sentCount = 0

    /// Never moves the stamp backwards. Its two callers read different
    /// clocks — one takes `Date()` directly, the other the coordinator's
    /// captured tick time — so without this the stamp could regress by the
    /// skew between them and grant an early refresh.
    mutating func noteActivity(at date: Date) {
        lastActivityAt = max(lastActivityAt ?? date, date)
    }

    /// Stamp optimistically at injection, because that instant IS the start
    /// of the request whose write the window is measured from.
    ///
    /// It is NOT undone when the refresh turns out to have failed, and that
    /// is a decision rather than an omission — a rollback was written,
    /// shipped for one round, and removed. See the failure branch in
    /// `ShimProcess.consumeKeepAliveTraffic` for the retry storm it caused.
    mutating func noteKeepAliveSent(at date: Date) {
        noteActivity(at: date)
        sentCount += 1
    }

    /// Why this gate declines, or nil when a refresh is due.
    ///
    /// `hasCustomApi` skips sessions running against a caller-supplied
    /// provider. The CLI grants the 1-hour TTL on `reason:"subscriber"` and
    /// falls back to `5m` otherwise, so on those sessions the cache this
    /// defends is already gone by the time the interval elapses and every
    /// refresh would buy a full write instead of a hit — the exact cost
    /// this feature exists to avoid, inverted. It is a conservative proxy,
    /// not a measurement: `ENABLE_PROMPT_CACHING_1H` can widen a custom
    /// provider's window and this cannot see it. Declining wrongly costs
    /// nothing; permitting wrongly bills every hour.
    ///
    /// Ordered so the cheapest and most diagnostic reason wins: the
    /// provider carve-out, then interval validity, then whether anything is
    /// cached, then freshness, and only then the quota ceiling. A fresh
    /// session at 100% quota therefore reports freshness rather than quota,
    /// which the probe pins — otherwise it would be an accident of how the
    /// guards happen to be written.
    func ineligibilityReason(
        now: Date,
        interval: TimeInterval = KeepAliveGate.defaultInterval,
        rateLimitPct: Int,
        hasCustomApi: Bool
    ) -> String? {
        if hasCustomApi { return "custom API provider (cache window likely 5m, not 1h)" }
        // `Int(_: Double)` traps on a non-finite value, and the interval
        // arrives as a parameter. `CANOPY_KEEPALIVE_MINUTES=inf` parses to
        // `.infinity`, and the coordinator rejects it one step earlier
        // (`minutes.isFinite`) — so this is NOT reachable through the env
        // var today. It is the pure type declining to depend on a caller's
        // validation, since anything may hand it an interval and a type
        // whose job is to be totally evaluable should not trap. An earlier
        // revision of this comment claimed a reachable crash; it was wrong.
        guard interval.isFinite, interval > 0 else {
            return "interval is not a usable number (check CANOPY_KEEPALIVE_MINUTES)"
        }
        guard let lastActivityAt else { return "no API activity yet — nothing cached to keep" }
        let elapsed = now.timeIntervalSince(lastActivityAt)
        guard elapsed >= interval else {
            return "cache still fresh (\(Int(elapsed / 60))m of \(Int(interval / 60))m)"
        }
        guard rateLimitPct < Self.rateLimitCeiling else {
            return "5h window at \(rateLimitPct)% (ceiling \(Self.rateLimitCeiling)%)"
        }
        return nil
    }
}
