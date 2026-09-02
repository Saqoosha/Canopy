import AppKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "KeepAlive")

/// Decides *when* to refresh a session's prompt cache — the timing half of
/// the keep-alive, with `ShimProcess.requestKeepAlive()` as the sending
/// half. `KeepAliveGate` owns the rules; this type owns the clock and the
/// fan-out.
///
/// The economics, which are the whole reason this exists — **and the ratio
/// is model-dependent, which an earlier revision of this comment got wrong
/// in five places including user-facing Settings copy.** Anthropic prices a
/// 1-hour cache write at 2x base input; a cache read is 0.1x base input on
/// most models and 0.025x on Claude Fable 5.1. So rebuilding a lapsed prefix
/// costs **20x** what reusing it does on an ordinary model, and 80x on Fable
/// 5.1. Canopy sessions run whatever model the user picked, so 20x is the
/// figure to reason with and 80x is the best case, not the rule.
///
/// Either way one small turn every 55 minutes is far cheaper than letting
/// the window lapse: the break-even is ~20 refreshes, so roughly a day of
/// being kept warm costs what a single miss would have. Leaving a session
/// overnight and returning to it is cheaper with this on, and the conclusion
/// needs no tuning even though the exact multiple does.
///
/// **The multiple does not describe the FIRST refresh after a lapse.** The
/// gate declines while the cache is fresh; it never declines because the
/// cache is hopelessly stale, and `DispatchQueue.main.asyncAfter` does not
/// fire while the Mac is asleep. So the first tick after a lid-close sees
/// hours of elapsed time and sends a refresh into a window that lapsed long
/// ago — a full cache WRITE, not a hit, once per sleep/wake cycle per pane.
/// That write is not extra in the usual case: the user's own next turn would
/// have paid it anyway, and paying it early leaves the prefix warm. It IS
/// wasted on a wake where that pane is never used.
///
/// Declining past the TTL is the obvious guard and is deliberately not
/// applied, because its wrong state is easy to name: `lastActivityAt` only
/// advances on a real turn or a sent refresh, so a pane declined for being
/// too stale would be declined forever after a single long sleep, and the
/// feature would switch itself off permanently for anyone who closes the
/// lid. Fixing that needs a stamp-on-decline, which is the optimistic-stamp
/// trap this feature has already been bitten by twice. Recorded rather than
/// patched.
///
/// **There is a cheaper technique Canopy cannot reach.** Anthropic documents
/// re-sending the previous request with `max_tokens: 0`, which re-arms the
/// entry's timer, bills only a cache read, and writes nothing to the
/// conversation. Canopy drives the CLI through the Claude Code extension and
/// never constructs the API request itself, so that parameter is not
/// available here — which is the actual reason this feature spends a real
/// turn and a few output tokens, rather than a preference.
///
/// **Scope is the open panes, and that is the whole stopping rule.**
/// There is deliberately no elapsed-time cap, because time is the wrong
/// axis: a refresh only wastes money on a session the user never comes back
/// to, and an hour count says nothing about that. A time cap would also
/// misfire precisely where the feature pays best — set it at six hours and
/// an overnight absence, the case worth the most, is abandoned four hours
/// before the user returns, while every short absence never reaches the cap
/// at all. "Is it on screen, in a running Canopy" is the user's own
/// standing answer to "am I coming back to this", expressed by a gesture
/// they already make: closing the pane stops the refreshes, and quitting
/// stops all of them. Nothing new has to be learned or configured.
///
/// **"Open", not "on screen" — a hidden window still counts, deliberately.**
/// A reviewer read the earlier wording ("visible panes") as a contract this
/// violates, since `windowCloseOnly` orders the window out rather than
/// closing it while sessions are running, and its panes survive. The
/// wording was what was wrong. That function hides the window *because*
/// sessions are running, explicitly "so Cmd+0 can bring the window back" —
/// which is the user saying they are coming back, and the overnight case
/// this feature pays best on. Skipping there would switch the feature off
/// in exactly the shape it exists for. The accepted cost is that a user who
/// hides the window and never returns keeps paying; that is the same
/// never-returns case the whole design already names as its only loss, and
/// closing the pane or quitting still ends it.
///
/// Panes are also nearly a hard boundary rather than a policy: a keep-alive
/// can only be injected into a live shim, so closed and `.dormant` rows are
/// unreachable regardless. What the pane scope adds on top is excluding an
/// open session that has no pane.
///
/// Note this is the opposite scoping argument from `RecapCoordinator`,
/// which fans out over panes to *limit* spend. Here the panes are the set
/// worth spending on.
@MainActor
final class KeepAliveCoordinator {
    static let shared = KeepAliveCoordinator()

    /// How often eligibility is re-examined. Independent of the refresh
    /// interval: this is the granularity with which a session that just
    /// came due is noticed, so it bounds how far past 55 minutes a refresh
    /// can land. One minute against five minutes of margin.
    private static let tickInterval: TimeInterval = 60

    /// `CANOPY_KEEPALIVE_MINUTES` overrides the refresh interval so the
    /// feature can be exercised without a 55-minute wait per attempt. It can
    /// lengthen it as well as shorten it. Clamped to ≥1 minute — below that
    /// the tick cadence, not the setting, would decide when it fires, which
    /// makes the override look broken rather than fast; the clamp says so in
    /// the log rather than silently substituting a different number.
    ///
    /// **Parsed exactly once.** This was a computed property, so every tick
    /// re-read the environment — and a value that fails to parse logs an
    /// error, so one typo produced an error a minute for the life of the
    /// process, roughly 1440 archived lines a day, saying the same thing.
    /// The environment cannot change while the process runs, so there was
    /// never anything to re-read. `static let` also makes the complaint fire
    /// once, at the first access, which is where someone debugging their own
    /// typo will actually look.
    private static let interval: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["CANOPY_KEEPALIVE_MINUTES"] else {
            return KeepAliveGate.defaultInterval
        }
        guard let minutes = Double(raw), minutes.isFinite else {
            logger.error("CANOPY_KEEPALIVE_MINUTES=\(raw, privacy: .public) is not a usable number — using \(KeepAliveGate.defaultInterval / 60)m")
            return KeepAliveGate.defaultInterval
        }
        if minutes * 60 < 60 {
            logger.notice("CANOPY_KEEPALIVE_MINUTES=\(raw, privacy: .public) clamped up to 1m")
        }
        return max(60, minutes * 60)
    }()

    private var pendingTick: DispatchWorkItem?

    private init() {}

    /// Begin the tick loop. Idempotent — a second call is ignored rather
    /// than starting a second self-rescheduling chain, which would double
    /// the tick rate permanently with no way to wind back down.
    func start() {
        guard pendingTick == nil else { return }
        // `notice`: whether the loop started at all is a once-per-launch
        // fact, and it is the first thing to check when a session went cold.
        logger.notice("KeepAliveCoordinator started (interval \(Self.interval / 60, privacy: .public)m)")
        scheduleTick()
    }

    /// Self-rescheduling main-queue work item, the same shape `recapTimeout`
    /// and the background-task idle backstop already use — no new object
    /// kind, and cancellable.
    ///
    /// The isolation trap recorded in CLAUDE.md is NOT the reason: it fires
    /// when an isolation-inheriting closure runs OFF the main queue, and this
    /// one is dispatched to the main queue. An earlier revision of this
    /// comment claimed otherwise, which contradicted the unwrapped sibling
    /// closures in `ShimProcess` that use the identical API.
    private func scheduleTick() {
        pendingTick?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                KeepAliveCoordinator.shared.tick()
            }
        }
        pendingTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickInterval, execute: work)
    }

    private func tick() {
        defer { scheduleTick() }
        guard CanopySettings.shared.keepAliveEnabled else { return }
        guard let store = SessionStore.shared else {
            logger.error("keep-alive tick: SessionStore.shared is nil — no panes examined")
            return
        }

        let now = Date()
        let interval = Self.interval
        // **A blocking ceiling has to be able to unblock itself.** Quota
        // percentages only move when a turn talks to the API, and this gate
        // exists precisely for sessions that are not doing that — so once
        // `sessionPct` crosses the ceiling while the user is away, nothing
        // ever lowers it again and the feature stays off for the rest of the
        // night even after the five-hour window resets. Reading an elapsed
        // `sessionResetDate` as a fresh window is what releases it.
        //
        // The state this is wrong in: the reset time has passed but the
        // server has not actually rolled the window over, so one refresh
        // goes out slightly early. That costs a single cheap call, against a
        // latch that otherwise cannot release at all.
        let limits = SharedRateLimitData.shared
        let quotaWindowElapsed = limits.sessionResetDate.map { $0 <= now } ?? false
        let rateLimitPct = quotaWindowElapsed ? 0 : limits.sessionPct
        var sent = 0
        var sessionPanes = 0
        for (index, pane) in store.panes.enumerated() {
            guard case .session(let id) = pane.content else { continue }
            sessionPanes += 1
            guard let session = store.openSessions.first(where: { $0.id == id }),
                  let shim = session.shim
            else { continue }
            // Debug, not info: unlike the recap's once-per-return fan-out
            // this runs every minute per pane, so a per-pane info line
            // would be the loudest thing in the log by two orders of
            // magnitude and would push `[bg]` notices out of the ring
            // buffer. The decision that matters — an actual send — is
            // logged at info by `requestKeepAlive`.
            if let reason = shim.keepAliveIneligibilityReason(now: now, interval: interval, rateLimitPct: rateLimitPct) {
                logger.debug("pane \(index, privacy: .public): keep-alive skipped — \(reason, privacy: .public)")
                continue
            }
            shim.requestKeepAlive(at: now)
            sent += 1
        }
        if sent > 0 {
            // `notice`, not `info`: `info` is never archived, so "did the
            // refresh run last night?" would be unanswerable the one morning
            // it matters. The denominator counts SESSION panes — launcher
            // panes can never receive a refresh, and including them read as
            // if a session had been skipped.
            logger.notice("keep-alive sent for \(sent, privacy: .public)/\(sessionPanes, privacy: .public) session pane(s)")
        }
    }
}
