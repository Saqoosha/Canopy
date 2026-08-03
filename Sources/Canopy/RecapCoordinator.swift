import AppKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RecapCoordinator")

/// Decides *when* to buy a session recap — Canopy's port of the Claude Code
/// CLI's `away_summary` feature.
///
/// The CLI watches terminal focus (DEC 1004 focus reporting) and, once the
/// terminal has been blurred for ~3 minutes, forks the conversation to
/// generate a ≤40-word "here's where we left off" note that is waiting for
/// the user when they come back. Canopy can't inherit that: the CLI runs in
/// `-p --output-format stream-json` print mode, where the Ink REPL that owns
/// the feature is never mounted. `ShimProcess.requestRecap()` reproduces the
/// generation half by injecting `/recap`; this type reproduces the timing.
///
/// Being a native app makes the focus half strictly better than the CLI's:
/// `NSApplication` tells us about activation directly, no escape-sequence
/// handshake to negotiate.
///
/// Scope is deliberately the visible panes, not every open session. A recap
/// costs a cache-read of the whole conversation, so fanning out across a
/// long sidebar would be a real bill for summaries nobody asked to see.
/// Panes are capped at 5 and are, by definition, what the user is looking
/// at when they come back.
@MainActor
final class RecapCoordinator {
    static let shared = RecapCoordinator()

    /// Background dwell time before a recap is worth buying. Matches the
    /// away-summary default of 180 s read out of the bundled CLI (2.1.218,
    /// 2026-08). Short enough to cover a coffee break, long enough that
    /// alt-tabbing to a browser and straight back doesn't spend anything.
    private static let defaultIdleDelay: TimeInterval = 180

    /// `CANOPY_RECAP_DELAY_SECONDS` shortens the dwell so the feature can be
    /// exercised without a three-minute wait per attempt. Clamped to ≥5s:
    /// below that the request would routinely land while the session is
    /// still streaming its last turn, which the eligibility check would then
    /// reject, making the override look broken rather than fast.
    private static var idleDelay: TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["CANOPY_RECAP_DELAY_SECONDS"] else {
            return defaultIdleDelay
        }
        guard let seconds = Double(raw) else {
            logger.error("CANOPY_RECAP_DELAY_SECONDS=\(raw, privacy: .public) is not a number — using \(defaultIdleDelay)s")
            return defaultIdleDelay
        }
        return max(5, seconds)
    }

    private var pendingFire: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Begin watching app activation. Idempotent — a second call is ignored
    /// rather than double-registering the notification observers. Harmless
    /// today (the second `appDidResignActive` just cancels and replaces the
    /// first work item, so the net effect is still one fire) but the observer
    /// array would grow unbounded and every log line would double.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { RecapCoordinator.shared.appDidResignActive() }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { RecapCoordinator.shared.appDidBecomeActive() }
            },
        ]
        logger.info("RecapCoordinator started")
    }

    private func appDidResignActive() {
        cancelPending()
        guard CanopySettings.shared.recapEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        pendingFire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    private func appDidBecomeActive() {
        // The user is back before the dwell elapsed, so a recap would only
        // tell them what they just watched happen. This does NOT cancel a
        // recap already in flight inside ShimProcess: it was requested while
        // they were away, it costs nothing more to finish, and it lands in
        // the strip a moment later — which is the intended UX.
        //
        // An earlier round DID close the shim's swallow window here, to stop
        // a slash command the user ran on return from being mistaken for the
        // recap. That was reverted: passing recap traffic through also fed
        // the untagged `result` to `SubagentTracker` and `extractStatusData`,
        // which froze live subagent rows and blanked the context bar — a
        // worse failure than the one it fixed. See the known limitation in
        // `consumeRecapTraffic`.
        cancelPending()
    }

    private func cancelPending() {
        pendingFire?.cancel()
        pendingFire = nil
    }

    /// Fire one recap per eligible pane. Runs on the main actor after the
    /// dwell; re-checks activation because `DispatchWorkItem.cancel()` does
    /// not interrupt an item already dequeued.
    private func fire() {
        pendingFire = nil
        guard CanopySettings.shared.recapEnabled else { return }
        guard !NSApp.isActive else {
            logger.debug("recap fire skipped: app became active")
            return
        }
        guard let store = SessionStore.shared else {
            logger.error("recap fire: SessionStore.shared is nil — no panes examined")
            return
        }

        var requested = 0
        for (index, pane) in store.panes.enumerated() {
            guard case .session(let id) = pane.content else {
                logger.debug("pane \(index, privacy: .public): launcher, no session")
                continue
            }
            guard let session = store.openSessions.first(where: { $0.id == id }),
                  let shim = session.shim
            else {
                logger.debug("pane \(index, privacy: .public): no live shim")
                continue
            }
            // Log the specific gate rather than a bare skip: a recap that
            // never appears is otherwise indistinguishable from one that was
            // correctly declined, and the two need very different fixes.
            if let reason = shim.recapIneligibilityReason {
                logger.info("pane \(index, privacy: .public): skipped — \(reason, privacy: .public)")
                continue
            }
            shim.requestRecap()
            requested += 1
        }
        logger.info("recap fired for \(requested, privacy: .public)/\(store.panes.count, privacy: .public) panes")
    }
}
