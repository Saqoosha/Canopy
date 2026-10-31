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
/// Either way one small turn every 50 minutes is far cheaper than letting
/// the window lapse — for a few hours. The CLI's idle compaction (one
/// summary, then a smaller context) is cheaper than an hourly refresh past
/// about four, so refreshing stops at `KeepAliveGate.maxUserIdle` and the
/// pane is left to it.
///
/// A cache already past its lifetime is never refreshed: after a sleep the
/// refresh would be a full write for a pane that may never be used. The pane
/// stays declined until the user's next turn there, which pays that write
/// anyway and restarts the clock.
///
/// **There is a cheaper technique Canopy cannot reach.** Anthropic documents
/// re-sending the previous request with `max_tokens: 0`, which re-arms the
/// entry's timer, bills only a cache read, and writes nothing to the
/// conversation. Canopy drives the CLI through the Claude Code extension and
/// never constructs the API request itself, so that parameter is not
/// available here — which is the actual reason this feature spends a real
/// turn and a few output tokens, rather than a preference.
///
/// **Scope is the open panes (in the daemon, sessions with an attached
/// client — `targets`).** Closing the pane stops its refreshes and quitting
/// stops all of them; within that scope `maxUserIdle` is the time limit.
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
    /// came due is noticed, so it bounds how far past 50 minutes a refresh
    /// can land. One minute against the four before the CLI's idle compaction.
    private static let tickInterval: TimeInterval = 60

    /// `CANOPY_KEEPALIVE_MINUTES` overrides the refresh interval so the
    /// feature can be exercised without a 50-minute wait per attempt. At or
    /// past `KeepAliveGate.cacheLifetime` nothing is ever sent. Clamped to ≥1 minute — below that
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

    /// The daemon's sessions worth keeping warm: running, with a client attached.
    /// It has no panes; an attached client is its "someone is coming back".
    static func daemonTargets(_ sessions: [OpenSession]) -> [OpenSession] {
        sessions.filter { isDaemonTarget(mirrorCount: $0.shim?.mirrorCount) }
    }

    /// `mirrorCount` nil: no shim running.
    nonisolated static func isDaemonTarget(mirrorCount: Int?) -> Bool {
        (mirrorCount ?? 0) > 0
    }

    /// Where `tick` looks. The GUI keeps the pane scope; the daemon sets `daemonTargets`.
    var targets: (SessionStore) -> [(label: String, session: OpenSession)] = { store in
        store.panes.enumerated().compactMap { index, pane in
            guard case .session(let id) = pane.content,
                  let session = store.openSessions.first(where: { $0.id == id }) else { return nil }
            return ("pane \(index)", session)
        }
    }

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
        // Quota percentages only move on API traffic, so an elapsed reset
        // date reads as an empty window (`keepAliveQuotaPct`); otherwise a
        // ceiling hit would outlive the window it was measured in.
        //
        // The state this is wrong in: the reset time has passed but the
        // server has not actually rolled the window over, so one refresh
        // goes out slightly early. That costs a single cheap call, against a
        // latch that otherwise cannot release at all. The read is inside
        // the loop, on the pane's own account.
        var sent = 0
        let candidates = targets(store)
        let sessionPanes = candidates.count
        for (label, session) in candidates {
            guard let shim = session.shim else { continue }
            // The ceiling is the ACCOUNT's, so read the record this session
            // writes into. A remote session whose account has not resolved
            // yet reads this Mac's, which can permit wrongly (local 10 %,
            // remote 95 %) — but only inside the resolve window, at most
            // 20 s after spawn, when `channelId` and `lastActivityAt` keep
            // the gate shut anyway.
            let limits = shim.rateLimitAccount ?? SharedRateLimitData.shared.local
            let rateLimitPct = limits.keepAliveQuotaPct(now: now)
            // Debug, not info: unlike the recap's once-per-return fan-out
            // this runs every minute per pane, so a per-pane info line
            // would be the loudest thing in the log by two orders of
            // magnitude and would push `[bg]` notices out of the ring
            // buffer. The decision that matters — an actual send — is
            // logged at info by `requestKeepAlive`.
            if let reason = shim.keepAliveIneligibilityReason(now: now, interval: interval, rateLimitPct: rateLimitPct) {
                logger.debug("\(label, privacy: .public): keep-alive skipped — \(reason, privacy: .public)")
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
