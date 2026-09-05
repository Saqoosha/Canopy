import Foundation
import Observation
import Security
import os.log

/// The one field `receiveReplies` needs to pick which of the two envelope
/// decoders to try — see the call site for why a peek beats trying both.
private struct RosterEnvelopeKind: Codable {
    let type: String
}

/// Publishes this Mac's panes to the relay whenever they change.
///
/// The tracking shape is `MacroPadController`'s: one `withObservationTracking`
/// pass that does the real work — decide, connect if needed, compose the
/// snapshot, send — and re-arms itself on the next change. That is
/// `MacroPadController.refresh()`'s own subtlety, copied deliberately:
/// *every* property read inside the tracked closure is what re-arms the
/// observation, including `settings.rosterEnabled`, which is why flipping
/// the toggle in Settings wakes this on its own, with no separate observer.
/// `settings.rosterEndpoint` is read only inside `connectIfConfigured()`,
/// which `publish()` calls only when `task == nil` — once connected it
/// drops out of the tracked set, so editing the endpoint takes effect on
/// the next reconnect (a toggle off/on, or the socket dropping on its own),
/// not immediately. An earlier revision tracked a discarded `snapshot()`
/// and called `publish()` only from `onChange` — that read pane data but
/// never the settings gate, so the toggle did nothing until some unrelated
/// pane mutation happened to fire `onChange` afterwards, and `start()`
/// armed tracking without ever publishing once.
///
/// A snapshot is always FULL. The Durable Object replaces rather than merges,
/// so a dropped update cannot leave a closed pane on the phone forever.
@MainActor
final class RosterPublisher {
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Roster")
    private let store: SessionStore
    private let settings: CanopySettings
    private var task: URLSessionWebSocketTask?
    private var stateSince: [OpenSession.ID: Int] = [:]
    private var lastStates: [OpenSession.ID: String] = [:]
    private var running = false

    /// The endpoint `task` was built against, so a later edit to
    /// `settings.rosterEndpoint` can be noticed. Nil whenever `task` is.
    private var connectedEndpoint: String?

    /// Guards the single resend in the send-failure handler against looping
    /// when the network is down.
    private var resendingAfterFailure = false

    /// Liveness ping for the publisher socket.
    ///
    /// **A half-open socket produces no error at all** — measured 2026-09-05
    /// on a Mac Studio: the receive loop had been armed for 47 minutes, the
    /// socket was gone, and neither `receiveReplies` nor a `send` ever
    /// failed. The relay's Durable Object still held its end, so `POST
    /// /reply` answered 200 and the phone reported the message as sent while
    /// nothing arrived. The user typed into a session that never heard them.
    ///
    /// The receive loop's own comment records why there was deliberately no
    /// timer here: recovery was meant to be the next observed pane change,
    /// and making the failure visible was thought to be enough. That reasoning
    /// assumed the socket would report its death. It does not, so nothing was
    /// visible and an idle Mac — the one with no pane changes to recover on —
    /// stayed silently unreachable.
    private var pingTimer: DispatchSourceTimer?

    /// Far below any NAT or load-balancer idle timeout, and cheap: one frame,
    /// no payload. The cost of a missed detection is a message the user
    /// believes they sent, so this errs short.
    private static let pingInterval: TimeInterval = 30

    /// When the last reconnect-after-loss ran, so failures cannot compound
    /// into a tight loop.
    private var lastReconnectAt: Date?

    /// The last retry armed because the rate floor was hit. Held so a second
    /// loss arriving in the meantime replaces it rather than stacking one.
    ///
    /// **It is not cleared when it fires**, so a non-nil value means "the
    /// last one armed", not "one is pending". Nothing reads it as a
    /// condition — the only uses are `cancel()`, and `cancel()` on a spent
    /// item is a no-op — so the imprecision costs one retained object and no
    /// behaviour. Clearing it from inside the item was tried and reverted:
    /// the identity check it needs (`reconnectWork === work`) makes the
    /// closure capture the very `let` it initializes, which **crashes
    /// swiftc 6.3.3** in the SendNonSendable SIL pass rather than diagnosing
    /// it, and clearing without the check would orphan a newer item armed
    /// between this one firing and its `Task` running.
    private var reconnectWork: DispatchWorkItem?

    /// Called with each reply that arrives down the publisher socket. Set by
    /// `AppDelegate` at start, because the publisher owns the connection but
    /// not the sessions.
    var onReply: ((ReplyEnvelope) -> Void)?

    /// Called with each permission decision that arrives down the publisher
    /// socket. Set alongside `onReply`, same reason.
    var onDecision: ((DecisionEnvelope) -> Void)?

    /// The live publisher, for callers that cannot reach the `AppDelegate`
    /// instance holding it.
    ///
    /// Settings needs to poke this after a Keychain write (see
    /// `secretChanged()`), and the obvious route — `NSApp.delegate as?
    /// AppDelegate` — is WRONG here. Measured 2026-09-04: inside
    /// `AppDelegate.startRosterPublisher`, `NSApp.delegate === self` is
    /// **false**, so SwiftUI's `@NSApplicationDelegateAdaptor` hands the
    /// scene a different instance from the one installed on `NSApp`. That
    /// route therefore reached a second `AppDelegate` whose
    /// `rosterPublisher` is nil, and did nothing at all — silently, which
    /// is the same invisible-failure shape `secretChanged()` exists to fix.
    /// Weak so quitting still deallocates the publisher.
    private(set) static weak var current: RosterPublisher?

    init(store: SessionStore, settings: CanopySettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        RosterPublisher.current = self
        observe()
    }

    func stop() {
        running = false
        if RosterPublisher.current === self { RosterPublisher.current = nil }
        connectedEndpoint = nil
        stopPinging()
        cancelScheduledReconnect()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        stateSince.removeAll()
        lastStates.removeAll()
    }

    /// Called when the relay secret in the Keychain has just changed.
    ///
    /// The Keychain is not observable, so a save in Settings moves nothing
    /// this publisher's `withObservationTracking` pass reads, and
    /// `connectIfConfigured()` is only reached from `publish()`, which only
    /// runs on an observed change. Without this, a first-time setup stayed
    /// disconnected until some unrelated pane or settings mutation happened
    /// to wake the closure — in practice, until the next launch.
    func secretChanged() {
        guard running else { return }
        stopPinging()
        // Not because the item holds the old secret — it reads the Keychain
        // at fire time, and `commitRelaySecret` writes it before calling
        // here, so it would pick up the new one. It is cancelled so a pending
        // item cannot race the deliberate attempt `publish()` makes below.
        cancelScheduledReconnect()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        publish()
    }

    private func observe() {
        withObservationTracking {
            publish()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.observe()
            }
        }
    }

    private func connectIfConfigured() {
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return }
        components.path = "/publish"
        components.queryItems = [URLQueryItem(name: "machine", value: machineId)]
        // Refuse anything but https. The old `http -> ws` branch existed for
        // a local Worker and shipped, which meant an endpoint typed with
        // `http://` sent the relay secret as a Bearer header over an
        // UNENCRYPTED WebSocket (CWE-319, found by review on PR #177).
        // Deliberately no loopback carve-out: ws://127.0.0.1 could not be
        // intercepted and would be a defensible exception, but nobody is
        // developing the Worker locally today, and a carve-out is a second
        // path to get wrong. Add it when someone actually needs it.
        guard components.scheme == "https" else {
            logger.error("roster endpoint must be https; refusing to send the secret over \(components.scheme ?? "no scheme", privacy: .public)")
            return
        }
        components.scheme = "wss"
        guard let url = components.url else {
            logger.error("roster endpoint is not a usable URL")
            return
        }
        guard let secret = RosterPublisher.sharedSecret() else {
            // Nothing to authenticate with. Log the decision, never the value.
            logger.notice("roster: no relay secret in the Keychain; not connecting")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task
        startPinging(on: task)
        connectedEndpoint = settings.rosterEndpoint
        logger.notice("roster: connected as \(machineId, privacy: .public)")
        receiveReplies(on: task)
    }

    /// Reads replies typed on the phone off the publisher socket, one at a
    /// time, for the life of `task`.
    ///
    /// Re-arms itself after every message, but only while `self.task` is
    /// still the SAME task it was armed on — `publish()` and `secretChanged()`
    /// both drop `task` (to nil, or to a fresh one) on an endpoint change or
    /// a send failure, and a stale receive loop re-arming itself on the
    /// socket they just tore down would leak a second reader racing the new
    /// one. A failed receive (the socket closing) ends this loop only; the
    /// next `connectIfConfigured()` call arms a fresh one on the new task,
    /// so there is deliberately no retry here.
    /// Builds the ping timer.
    ///
    /// **`nonisolated`, and that is load-bearing.** `DispatchSourceHandler` is
    /// a plain `@convention(block) () -> Void` with no `@Sendable`, so a
    /// closure literal written inside this `@MainActor` type inherits its
    /// isolation and the compiler emits a main-queue check at the closure's
    /// entry. The timer fires on its own queue, so the first tick aborts the
    /// process — measured 2026-09-05: the app died ~30 s after launch, once
    /// per run, with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to
    /// execute on queue [com.apple.main-thread]`.
    ///
    /// Hopping to the main actor INSIDE the handler does not help, and a
    /// comment here claimed it did: the entry check runs before the hop.
    /// `PeerNameStore.makeWatcher` carries the same annotation for the same
    /// reason. The rule is about the parameter's type, not the body.
    private nonisolated static func makePingTimer(
        for task: URLSessionWebSocketTask,
        interval: TimeInterval,
        onFailure: @escaping @Sendable (URLSessionWebSocketTask, Error) -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak task] in
            guard let task else { return }
            task.sendPing { error in
                guard let error else { return }
                onFailure(task, error)
            }
        }
        return timer
    }

    /// Starts pinging `task`, replacing any timer armed on an older one.
    private func startPinging(on task: URLSessionWebSocketTask) {
        stopPinging()
        let timer = Self.makePingTimer(for: task, interval: Self.pingInterval) { failed, error in
            Task { @MainActor in
                guard let self = RosterPublisher.current, self.task === failed else { return }
                self.logger.notice("roster: ping failed, reconnecting: \(error.localizedDescription, privacy: .public)")
                self.reconnectAfterLoss()
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPinging() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    /// Cancels a deferred reconnect. Called wherever the publisher is being
    /// torn down or deliberately disabled, so a retry cannot fire into a
    /// state the user just asked for.
    private func cancelScheduledReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
    }

    /// Drops the dead socket and rebuilds one on this publisher's own clock.
    ///
    /// **On its own clock, not on the next publish.** The Mac this matters
    /// for is the idle one: it has no pane changes to trigger a publish, so
    /// waiting for one means waiting forever, which is the state that was
    /// measured. The first attempt is immediate; one inside the rate floor is
    /// deferred by the remainder, never skipped — see `RosterReconnectFloor`.
    private func reconnectAfterLoss() {
        stopPinging()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectedEndpoint = nil
        guard running else { return }
        // **A floor that DEFERS, never one that skips.** Offline,
        // `connectIfConfigured()` builds a socket whose receive fails within
        // seconds, landing straight back here — so without a floor the two
        // chase each other as fast as the network can refuse, each pass
        // logging. But an early `return` here was worse than no floor at
        // all: it left `task` and `pingTimer` both nil with nothing armed to
        // try again, and the only other callers of `connectIfConfigured()`
        // are `publish()` (an observed pane change) and `secretChanged()`.
        // On the idle Mac this whole feature is for, that is never — the
        // exact state the ping was added to end, reintroduced by its own
        // rate limit. Caught in review; the comment here had claimed the
        // opposite.
        let now = Date()
        switch RosterReconnectFloor.decide(last: lastReconnectAt, now: now, floor: Self.pingInterval) {
        case .now:
            lastReconnectAt = now
            // `connectIfConfigured()` can itself decline — no Keychain
            // secret, a non-https endpoint, an unusable URL — and then this
            // branch arms nothing, which is the Critical's shape reached
            // through a different door. It self-heals rather than sticking:
            // `publish()` reads `rosterEndpoint` unconditionally so an
            // endpoint fix wakes the tracked closure, and a secret fix comes
            // through `secretChanged()`. Recorded rather than guarded,
            // because a guard here would need its own retry clock.
            connectIfConfigured()
        case .after(let delay):
            scheduleReconnect(after: delay)
        }
    }

    /// Arms a single deferred reconnect. Replacing any pending one keeps a
    /// burst of losses from stacking attempts.
    ///
    /// **`DispatchQueue.main` is a requirement, not a choice.**
    /// `DispatchWorkItem`'s block parameter is not `@Sendable`, so this
    /// closure literal — written inside a `@MainActor` type — inherits the
    /// isolation and the compiler emits a main-queue entry check inside it
    /// (measured in the IR: `swift_task_reportUnexpectedExecutor` sits in the
    /// closure's own symbol). The inner `Task { @MainActor }` does not save
    /// it; that check runs before the hop, which is the whole of what
    /// `makePingTimer` above records. Move this to `.global(qos:)` and the
    /// process aborts on the first deferred reconnect — offline, which is the
    /// only time this code runs.
    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.task == nil else { return }
                self.lastReconnectAt = Date()
                self.connectIfConfigured()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func receiveReplies(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                // Two envelope shapes travel this socket now — a typed
                // reply and a permission decision — and they don't share a
                // decoder: `ReplyEnvelope` requires `text`, `DecisionEnvelope`
                // requires `requestId`/`decision`, so a decode attempt for
                // the wrong shape fails rather than silently producing a
                // half-populated value. Peek `type` first rather than
                // trying both decoders in sequence, so an unrecognized
                // future `type` is a no-op instead of two failed decodes.
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let kind = try? JSONDecoder().decode(RosterEnvelopeKind.self, from: data) {
                    switch kind.type {
                    case "reply":
                        if let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data) {
                            Task { @MainActor in self?.onReply?(envelope) }
                        }
                    case "decision":
                        if let envelope = try? JSONDecoder().decode(DecisionEnvelope.self, from: data) {
                            Task { @MainActor in self?.onDecision?(envelope) }
                        }
                    default:
                        break
                    }
                }
                Task { @MainActor in
                    guard let self, self.task === task else { return }
                    self.receiveReplies(on: task)
                }
            case .failure(let error):
                // A socket that reports its own death. This used to be the
                // only recovery trigger, and the comment here used to say
                // there was deliberately no ping and no timer — recovery
                // being the next observed pane change. That was measured
                // wrong twice over: a half-open socket never reports
                // anything, so this branch does not run, and an idle Mac has
                // no pane change to recover on either. `pingTimer` is the
                // trigger that covers both; this one stays because a socket
                // that DOES fail should not wait up to the ping interval.
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.notice("roster: receive failed, socket presumed dead: \(error.localizedDescription, privacy: .public)")
                    // Only clear OUR state if `task` is still the one this
                    // closure was armed on — `publish()`/`secretChanged()`
                    // may have already replaced it with a fresh, live
                    // socket, and clobbering that would silently kill a
                    // working connection instead of the dead one that
                    // actually failed.
                    guard self.task === task else { return }
                    // A reported failure is the easy case; recovery is the
                    // same either way, and going through one path means the
                    // ping and the receive loop cannot disagree about it.
                    self.reconnectAfterLoss()
                }
            }
        }
    }

    /// The relay secret, from the Keychain.
    ///
    /// **Not from the process environment.** Canopy is launched with `open`,
    /// which gives it no shell environment, so an env var would be empty in
    /// every normal launch and present only when a developer runs the binary
    /// from a terminal — working in exactly the case nobody ships. Not from
    /// `settings.json` either: that file is plaintext on disk and is SHARED
    /// with the installed Release build.
    ///
    /// `KeychainAuth` is the precedent for reading a secret in this app; this
    /// item is written by the Settings field in Task 3 and read here.
    private static func sharedSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty
        else { return nil }
        return secret
    }

    /// The relay secret, for `RosterNotifier`, which posts over HTTP rather
    /// than the socket and so cannot reuse the connection's own header.
    static func sharedSecretForNotifier() -> String? { sharedSecret() }

    /// Composes the full snapshot. Reading every property here is what arms
    /// the observation above — a field read only inside `publish()` would not
    /// trigger a re-publish when it changed.
    private func snapshot() -> RosterSnapshot? {
        guard let machineId = MachineIdentity.stableId() else { return nil }
        let indexes = RosterSnapshot.paneIndexes(in: store.panes)
        let now = Int(Date().timeIntervalSince1970)
        var rows: [RosterSnapshot.Pane] = []
        // Liveness is "still in `store.openSessions`", not "got a row this
        // pass" — an open session with no pane (`.dormant`, or displaced by
        // `openInFocusedPane`'s content-swap branch) is real and paneless is
        // routine, not closed. Keying off the emitted rows pruned exactly
        // those sessions' stamps, so giving one back its pane later read as
        // a brand-new state and reset `stateSince` to "0s" — losing the one
        // fact this field exists to keep.
        let liveIds = Set(store.openSessions.map(\.id))
        for session in store.openSessions {
            guard let paneIndex = indexes[session.id] else { continue }
            let activity = SessionActivity.of(
                session, isUnread: store.unreadSessionIds.contains(session.id))
            let wire = RosterSnapshot.wireState(for: activity)
            if lastStates[session.id] != wire {
                lastStates[session.id] = wire
                stateSince[session.id] = now
            }
            rows.append(RosterSnapshot.Pane(
                sessionId: session.id.uuidString,
                // `sessionId` above is minted per Canopy process, so it dies
                // with a restart and takes every stored notification's link to
                // this session with it — the phone showed a stale, empty
                // conversation and read as "the push never arrived" (measured
                // 2026-09-05). `resumeId` is the CLI's own id and survives, so
                // the phone groups history by it. Routing still uses the
                // process id, because a reply has to address a LIVE session
                // and only that id can.
                resumeId: session.resumeId.isEmpty ? nil : session.resumeId,
                paneIndex: paneIndex,
                title: session.title,
                project: session.projectLabel,
                state: wire,
                stateSince: stateSince[session.id] ?? now,
                contextPct: session.statusBar.contextPct,
                model: session.statusBar.model,
                messageCount: session.statusBar.messageCount))
        }
        // `OpenSession.ID` is a fresh UUID minted per process and never
        // reused, so without this both dictionaries grow for the life of a
        // long-running Canopy — one stranded entry per session that ever
        // closed. Pruned means removed from `store.openSessions`, never
        // merely absent from `rows` this pass — see `liveIds` above.
        stateSince = stateSince.filter { liveIds.contains($0.key) }
        lastStates = lastStates.filter { liveIds.contains($0.key) }
        let limits = SharedRateLimitData.shared
        return RosterSnapshot(
            machineId: machineId,
            displayName: MachineIdentity.resolvedDisplayName(
                setting: settings.machineDisplayName,
                fallback: MachineIdentity.defaultDisplayName()),
            publishedAt: now,
            sessionPct: limits.sessionPct,
            weeklyPct: limits.weeklyPct,
            panes: rows.sorted { $0.paneIndex < $1.paneIndex })
    }

    private func publish() {
        // Read unconditionally, ahead of every other branch below, so this
        // property always participates in re-arming the observation — the
        // toggle must be able to wake this on its own, off or on.
        guard settings.rosterEnabled else {
            // The toggle just went off (or was already off and something
            // else woke this pass). Either way, an open socket now
            // represents a decision the user reversed — close it rather
            // than merely declining to send into it.
            //
            // Both timers come down unconditionally, outside the `task`
            // check. A deferred reconnect is armed only while `task` is nil,
            // so guarding on a live socket would leave the one state that can
            // still reconnect after the user switched this off — note that is
            // one direction only: a pane change can rebuild the socket while
            // an item is still pending, and the item's own `task == nil`
            // guard is what makes that harmless. The ping timer is stopped
            // here to keep a deliberate toggle-off from logging "ping failed,
            // reconnecting" on its way out.
            stopPinging()
            cancelScheduledReconnect()
            if task != nil {
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
                stateSince.removeAll()
                lastStates.removeAll()
            }
            return
        }
        // Read unconditionally, for the same reason `rosterEnabled` is: it is
        // otherwise touched only inside `connectIfConfigured()`, which runs
        // only while `task == nil`, so the property DROPS OUT of the tracked
        // set the moment a socket exists. Typing a URL is what exposes that:
        // an early keystroke can already parse, a socket opens against the
        // fragment, and every remaining keystroke then wakes nothing — the
        // roster stays pointed at a partial host until a pane changes or the
        // toggle is cycled. Found by review on PR #177.
        let endpoint = settings.rosterEndpoint
        if task != nil, endpoint != connectedEndpoint {
            // The user edited the URL under a live socket. Drop it rather
            // than keep publishing to the host they just stopped naming.
            //
            // `stopPinging()` because the timer is armed on THIS task and
            // nothing below is guaranteed to replace it: `connectIfConfigured`
            // declines a half-typed URL at its https guard, so the timer would
            // outlive the socket and fire every 30 s forever — its failure
            // handler declining each time, since `self.task === failed` is
            // false. Found by review; a comment two screens down had asserted
            // this could not happen.
            stopPinging()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            connectedEndpoint = nil
        }
        guard let snapshot = snapshot() else { return }
        if task == nil { connectIfConfigured() }
        guard let task,
              let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard let error else {
                    // A send got through, so the next failure is allowed its
                    // own single resend.
                    self.resendingAfterFailure = false
                    return
                }
                // Drop the socket so the next change reconnects. A send error
                // on a hibernated peer is routine, not a fault.
                self.logger.notice("roster: send failed, will reconnect: \(error.localizedDescription, privacy: .public)")
                // Same reason as the endpoint-change branch above: the timer
                // is armed on the task being dropped here, and the resend
                // below can decline.
                self.stopPinging()
                self.task = nil
                self.connectedEndpoint = nil
                // Resend ONCE. Without this the dropped snapshot waits for the
                // next state change, and if the failed one WAS the last change
                // — entering `asking`, or a pane closing — the phone shows the
                // preceding state until something else happens. Found by
                // review on PR #177.
                //
                // The latch is cleared by a SUCCESSFUL send above, never here:
                // `publish()` returns as soon as the send is in flight, so
                // clearing it on the way out would leave it open by the time
                // the retry's own failure arrived, and a down network would
                // loop.
                //
                // **A closed latch must still reconnect.** It used to `return`
                // bare, which left no socket, no ping timer and a latch that
                // only a successful send could open — on an idle Mac, nothing
                // ever calls `publish()` again, so that Mac reconnected never.
                // That is the same sentence as the Critical this branch's own
                // commit fixed, reached through a second door: found by the
                // verification round, in code that predates the ping. The
                // latch is about not resending the SNAPSHOT twice; it was
                // never meant to stop the socket coming back, and
                // `reconnectAfterLoss()` is now the thing that guarantees it
                // does, on the same rate floor as every other loss.
                guard !self.resendingAfterFailure else {
                    self.reconnectAfterLoss()
                    return
                }
                self.resendingAfterFailure = true
                self.publish()
            }
        }
    }
}
