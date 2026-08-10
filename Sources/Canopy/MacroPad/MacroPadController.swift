import AppKit
import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MacroPad")

/// Tracks which sessions have finished a turn while the user was looking
/// somewhere else. Split out of `MacroPadController` as a pure value type so
/// the probe can exercise the edge cases without a `SessionStore`, a window,
/// or a device.
///
/// "Unread" has no counterpart in Canopy's own UI — it exists because the pad
/// answers a question the screen never had to: *did anything finish while I
/// wasn't looking?* With the pad mapped to panes, every mapped session is on
/// screen, so "not visible" can't be the trigger the way it could if the pad
/// mapped to sidebar rows. The trigger is the focused pane instead.
struct MacroPadUnreadTracker {
    struct Snapshot {
        let id: UUID
        let isThinking: Bool
        /// Which pane hosts this session, or nil when it isn't mapped to one.
        let paneIndex: Int?
    }

    private(set) var unread: Set<UUID> = []
    private var wasThinking: [UUID: Bool] = [:]

    /// `isAppActive` is not a refinement of `focusedPaneIndex` — it overrides
    /// it. The question unread answers is "did anything finish while I wasn't
    /// looking", and a focused pane in a background app is not being looked at.
    /// Without this, the one case the pad exists for — you walked away, a turn
    /// finished — produced no green at all, because the pane you left focused
    /// is the pane the turn finished in.
    mutating func update(_ sessions: [Snapshot], focusedPaneIndex: Int, isAppActive: Bool) {
        let live = Set(sessions.map(\.id))
        unread.formIntersection(live)
        wasThinking = wasThinking.filter { live.contains($0.key) }

        for session in sessions {
            let finished = (wasThinking[session.id] ?? false) && !session.isThinking
            wasThinking[session.id] = session.isThinking
            if finished { unread.insert(session.id) }
        }

        // Clearing runs after marking, deliberately: a turn that ends in the
        // pane the user is already looking at must never light up green. The
        // two-step ordering is what makes "finished while focused" and
        // "finished elsewhere, then focused" collapse to the same clean state
        // without a special case for either.
        //
        // It is skipped entirely while the app is in the background, which is
        // also what makes returning to Canopy clear the focused pane: the next
        // update after activation runs this loop again.
        guard isAppActive else { return }
        for session in sessions where session.paneIndex == focusedPaneIndex {
            unread.remove(session.id)
        }
    }

    mutating func reset() {
        unread.removeAll()
        wasThinking.removeAll()
    }
}

/// Sliding-window count of unexplained reconnects. Split out of
/// `MacroPadController` for the same reason as `MacroPadUnreadTracker`: it is
/// pure arithmetic over timestamps, and embedded in the controller a detector
/// that never fires and one that fires constantly are indistinguishable
/// without physically misbehaving hardware. It had in fact never been able to
/// fire — see `MacroPadController.resetLoopWindow`.
struct MacroPadResetLoopDetector {
    let window: TimeInterval
    let threshold: Int

    private var timestamps: [Date] = []

    init(window: TimeInterval, threshold: Int) {
        self.window = window
        self.threshold = threshold
    }

    /// Returns true exactly once per burst. The counter clears on a hit so a
    /// pad in a tight loop cannot bury the warning it is trying to raise.
    mutating func note(at now: Date) -> Bool {
        timestamps.append(now)
        timestamps.removeAll { now.timeIntervalSince($0) > window }
        guard timestamps.count >= threshold else { return false }
        timestamps.removeAll()
        return true
    }
}

/// Binds Canopy's session state to the MacroPad: pane activity out as LED
/// colors, key presses back in as pane focus.
///
/// Mapping is **pane index → key index**, which is Cmd+1..9's meaning, not
/// Cmd+Ctrl+1..9's. Panes cap at 5 (`SessionStore.paneAbsoluteCap`) while a
/// 4-key pad covers the first four; the fifth pane is knowingly invisible to
/// the pad until the 5/6-key build lands. Nothing here hardcodes four — the
/// count comes off the wire in `HELLO`.
@MainActor
final class MacroPadController {
    /// The count used whenever the device has not told us one — which is not
    /// only the sliver between adopting a port and reading `HELLO`, but the
    /// entire time no pad is connected, since `refresh()` runs regardless.
    /// Harmless there because `pushStates` sends nothing while disconnected.
    /// **This is the only hardcoded four in the subsystem**; a real count
    /// always comes off the wire.
    private static let assumedKeyCount = 4
    /// Nothing in the roadmap goes past a couple of NeoKey boards, and the
    /// value arrives from a serial line that can be garbled. `HELLO 3 99999999`
    /// would otherwise be believed, and `refresh()` would build that many
    /// states on the main actor and queue that many writes.
    private static let maxKeyCount = 64
    /// Protocol version that introduced `S` (breathe). Below it, animated
    /// states degrade to a steady color rather than being dropped.
    private static let breatheProtocolVersion = 2
    /// A powered pad that has quietly stopped listening produces no read
    /// traffic, so nothing would notice it. The ping's write is what fails,
    /// and the failure is what triggers a reconnect.
    private static let watchdogInterval: TimeInterval = 30

    private let store: SessionStore
    private let settings: CanopySettings
    private let device: MacroPadDevice
    private let status: MacroPadStatus

    /// A firmware crash more than a minute after boot makes the pad paint
    /// every key red, reboot, and reconnect — the recovery Canopy wants, and
    /// completely silent. A pad stuck in that cycle would heal forever with
    /// nobody the wiser, and the device cannot notice: a reset erases any
    /// count it kept. The host is the only vantage point from which repeated
    /// reboots are even visible.
    ///
    /// `HELLO` also arrives whenever *the host* opens the port, so launches
    /// and Settings-toggle flips are excluded explicitly — otherwise flipping
    /// the switch three times would tell the user their hardware is failing.
    /// Two host-initiated reopens are NOT excluded and can still false-positive:
    /// a hand-driven replug, and the reconnect that follows a write failure or
    /// an EOF. The cost of being wrong is one status-bar hint, which is the
    /// right side to err on.
    ///
    /// The window has to clear the firmware's own floor: it refuses to
    /// self-reset within a minute of booting, so a genuine crash loop cannot
    /// cycle faster than roughly once a minute. A 120 s window needed two gaps
    /// inside it and could therefore never fire on the thing it was built for
    /// — only on the false positives.
    private static let resetLoopWindow: TimeInterval = 360
    private static let resetLoopThreshold = 3

    private var keyCount: Int?
    private var protocolVersion: Int?
    private lazy var resetLoop = MacroPadResetLoopDetector(
        window: Self.resetLoopWindow, threshold: Self.resetLoopThreshold
    )
    private var isConnected = false
    /// Last command sent per key. Diffing whole commands rather than colors is
    /// what makes a period or floor change propagate; a color-only cache would
    /// silently swallow one.
    private var lastSentCommands: [Int: MacroPadCommand] = [:]
    private var lastBrightness: Int?
    private var states: [SessionActivity] = []
    private var tracker = MacroPadUnreadTracker()
    private var watchdogTimer: Timer?
    private var helloIsHostInitiated = false
    private var lastEnabled: Bool?
    /// Mirrors `NSApp.isActive`. Kept as stored state rather than read live
    /// because `refresh()` has to re-run when it changes, and AppKit's
    /// activation is a notification, not an observable property.
    private var isAppActive = NSApp?.isActive ?? true
    private var activationObservers: [NSObjectProtocol] = []

    init(store: SessionStore,
         settings: CanopySettings = .shared,
         device: MacroPadDevice = MacroPadDevice(),
         status: MacroPadStatus = .shared) {
        self.store = store
        self.settings = settings
        self.device = device
        self.status = status
    }

    func start() {
        device.setOutputHandler { [weak self] output in self?.handle(output) }
        device.setEnabled(settings.macroPadEnabled)
        expectHostInitiatedHello()
        device.start()
        startWatchdog()
        observeActivation()
        track()
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true),
                               (NSApplication.didResignActiveNotification, false)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isAppActive != active else { return }
                    self.isAppActive = active
                    self.refresh()
                }
            }
            activationObservers.append(token)
        }
    }

    /// Blanks the pad and closes the port synchronously. Call from
    /// `applicationWillTerminate`: a pad left displaying a blinking orange key
    /// after Canopy is gone is actively lying about a permission prompt that
    /// no longer exists.
    ///
    /// The firmware blanks itself when the host disconnects, which covers a
    /// crash or a yanked cable; this is the clean-exit path, not the only one.
    func shutdown() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
        // The observation loop stays armed, so leaving these set would let a
        // later `refresh()` walk straight past `pushStates`' connection guard
        // and send into a stopped device. It only ever worked because
        // `MacroPadDevice.send` also checks its own fd.
        isConnected = false
        lastSentCommands.removeAll()
        lastBrightness = nil
        // `.disabled` rather than `.searching`: the subsystem is stopped, not
        // hunting for a port. It is not a latch — the observation loop above
        // is still armed, so a `refresh()` before the process actually exits
        // republishes `.searching`. Accepted because the only caller is
        // `applicationWillTerminate` and the UI is already going away; a
        // second caller would need a real terminal state.
        status.publish(.disabled)
        device.stop(sendingReset: true)
    }

    // MARK: - Observation

    private func track() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            // `onChange` fires *before* the mutation lands, so re-reading here
            // would see the old value. Hopping to the next main-actor turn is
            // what makes the re-read observe the change that woke us.
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private func refresh() {
        // Every property read inside the tracked closure is what re-arms the
        // observation — including `settings.macroPadEnabled`, which is why
        // the toggle takes effect without its own observer.
        let enabled = settings.macroPadEnabled
        let brightness = settings.macroPadBrightness
        let panes = store.panes
        let focusedPaneIndex = store.focusedPaneIndex
        let openSessions = store.openSessions

        if lastEnabled != enabled {
            // A toggle Canopy performed will produce a `HELLO` that is not a
            // firmware reboot.
            if enabled { expectHostInitiatedHello() }
            lastEnabled = enabled
        }
        device.setEnabled(enabled)

        var paneIndexBySession: [UUID: Int] = [:]
        for (index, pane) in panes.enumerated() {
            if case .session(let id) = pane.content { paneIndexBySession[id] = index }
        }

        tracker.update(
            openSessions.map {
                MacroPadUnreadTracker.Snapshot(
                    id: $0.id,
                    isThinking: $0.isThinking,
                    paneIndex: paneIndexBySession[$0.id]
                )
            },
            focusedPaneIndex: focusedPaneIndex,
            isAppActive: isAppActive
        )
        // Publish so the sidebar's dot and the pad's LED read the same set.
        //
        // The comparison is what keeps the sidebar still: `@Observable`
        // notifies on every assignment, equal or not, so an unconditional
        // store would invalidate every row on each refresh — and `refresh`
        // runs on every observed change, including a pane-divider drag.
        // (It does not prevent an observation loop. Writing a property that
        // was never *read* inside the tracked closure cannot wake this
        // tracking; reading it here is what puts it in the tracked set at all.)
        if store.unreadSessionIds != tracker.unread {
            store.setUnreadSessionIds(tracker.unread)
        }

        let sessionsById = Dictionary(openSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        states = (0..<effectiveKeyCount).map { index -> SessionActivity in
            guard index < panes.count,
                  case .session(let id) = panes[index].content,
                  let session = sessionsById[id]
            else { return .empty }
            return SessionActivity.of(session, isUnread: tracker.unread.contains(id))
        }

        applyBrightness(brightness)
        pushStates()
        publishStatus()
    }

    /// Mirrors the link state out to the sidebar indicator. Driven from
    /// `refresh()` rather than from the connect/disconnect handlers alone,
    /// because the Settings toggle is a third input and only `refresh()`
    /// observes it.
    ///
    /// `MacroPadStatus.publish` drops no-op writes, so the common case is
    /// free. A publish from outside a tracked pass costs one extra `refresh()`
    /// — see `publish`'s own doc for why the ones from inside do not.
    ///
    /// The mapping into `Keys` lives here rather than in `adoptIdentity`
    /// because it needs `isConnected` as well as the count.
    private func publishStatus() {
        guard settings.macroPadEnabled else {
            status.publish(.disabled)
            return
        }
        guard isConnected else {
            status.publish(.searching)
            return
        }
        let keys: MacroPadStatus.Keys
        if let count = keyCount {
            keys = count == 0 ? .unreachable : .available(count)
        } else {
            keys = .counting
        }
        status.publish(.connected(keys))
    }

    private var effectiveKeyCount: Int { keyCount ?? Self.assumedKeyCount }

    // MARK: - Output

    private func pushStates() {
        guard isConnected else { return }
        for (index, state) in states.enumerated() {
            let command = Self.command(for: state, at: index, protocolVersion: protocolVersion)
            guard lastSentCommands[index] != command else { continue }
            lastSentCommands[index] = command
            device.send(command)
        }
    }

    /// One key's whole appearance in one command. Firmware older than
    /// `breatheProtocolVersion` has no `S` and would reject it — that key
    /// would sit dark with nothing but an `ERR` in the log to say why — so
    /// animated states fall back to their steady color there. The urgency
    /// ladder is lost on such a device; the state is not.
    static func command(for state: SessionActivity, at index: Int, protocolVersion: Int?) -> MacroPadCommand {
        guard let breath = state.breath,
              (protocolVersion ?? 1) >= Self.breatheProtocolVersion
        else {
            return .color(index: index, rgb: state.ledColor)
        }
        return .breathe(
            index: index,
            rgb: state.ledColor,
            periodMs: breath.periodMs,
            floorPercent: breath.floorPercent
        )
    }

    private func applyBrightness(_ percent: Int) {
        guard isConnected else { return }
        let clamped = min(100, max(0, percent))
        guard lastBrightness != clamped else { return }
        lastBrightness = clamped
        device.send(.brightness(percent: clamped))
    }

    /// Re-sends everything from a known-nothing state. Used on connect and on
    /// every `HELLO` — the device sends `HELLO` when the host opens the port
    /// *and* after a reset button press, so treating it as "your cached idea
    /// of my LEDs is void" makes reset recovery share one code path with
    /// first connect instead of needing its own.
    /// Drops the cache and re-derives everything, for the cases where the
    /// device's own state is unknown: a fresh connection, or a `HELLO` after
    /// the pad reset itself.
    ///
    /// Does **not** send `R` first. This flip-flopped three times on reasoning
    /// alone, so here is the evidence that settles it, from the firmware's
    /// `code.py` beside `NUM_KEYS`:
    ///
    /// > The key count in HELLO stays at its startup value even then.
    ///
    /// "Even then" is a runtime I²C loss. `NUM_KEYS` is module scope and never
    /// reassigned, so **the reported key count cannot shrink within one
    /// connection** — a smaller count implies a reboot, a reboot re-enumerates
    /// USB, and that path already blanks the pad twice over (the firmware's own
    /// blank-on-disconnect, then its blank at boot). The stranded-keys scenario
    /// the `R` was restored for does not exist.
    ///
    /// What the `R` did cost is real: the firmware restarts a key's phase when
    /// a steady key becomes a breathing one, so blanking first re-anchored
    /// every breathing key together and put `asking`'s deep breath in lockstep
    /// with `working`'s shallow one — collapsing the amplitude ladder that is
    /// the whole point of `SessionActivity.breath`. See `MacroPadCommand.breathe`.
    ///
    /// The one shrink that *can* happen inside a connection — an implausible
    /// count on the wire — is handled in `adoptIdentity`, which keeps the count
    /// it already had rather than lowering it.
    ///
    /// Recomputing through `refresh()` rather than pushing `states` directly
    /// is what keeps this from sending twice per `HELLO`: the callers used to
    /// `refresh()` and then `fullPush()`, and every changed key went out on
    /// both. (A connect still pushes twice — once for `.connected`, once for
    /// the identity line that arrived in the probe window — which the firmware
    /// absorbs as a no-op.)
    private func fullPush() {
        guard isConnected else { return }
        lastSentCommands.removeAll()
        lastBrightness = nil
        refresh()
    }

    private func startWatchdog() {
        // `[weak self]` belongs on the OUTER block: putting it only on the
        // inner `Task` still makes the timer's own closure capture `self`
        // strongly to form the weak reference, so the controller and the timer
        // retain each other.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.device.send(.ping)
            }
        }
        // Re-added in `.common` so the watchdog keeps running through menu
        // tracking and live resize, which the default mode suspends.
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    // MARK: - Input

    private func handle(_ output: MacroPadDevice.Output) {
        switch output {
        case .connected:
            isConnected = true
            fullPush()
        case .disconnected:
            isConnected = false
            keyCount = nil
            protocolVersion = nil
            lastSentCommands.removeAll()
            lastBrightness = nil
            // The disconnect branch never calls `refresh()`, so this is the
            // only republish on the path. (Adding a `fullPush()` here would
            // be inert anyway — it guards on `isConnected`, just cleared.)
            publishStatus()
        case .event(let event):
            handle(event)
        }
    }

    private func handle(_ event: MacroPadEvent) {
        switch event {
        case .hello(let version, let count):
            noteHello()
            adoptIdentity(version: version, keyCount: count)
            fullPush()
        case .pong(let version, let count):
            // Cheap safety net rather than a designed-for path: a physically
            // swapped pad re-enumerates and takes the `.disconnected` route.
            // `count` is only adopted when the device actually reported one —
            // otherwise a version-only answer would erase a known count and
            // silently drop a 6-key pad to the assumed four.
            let countChanged = count != nil && count != keyCount
            let versionChanged = version != nil && version != protocolVersion
            if countChanged || versionChanged {
                adoptIdentity(version: version ?? protocolVersion, keyCount: count ?? keyCount)
                fullPush()
            }
        case .key(let index, let pressed):
            // Release edges are forwarded by the firmware and deliberately
            // ignored here — press-to-focus is the whole Phase 1 gesture, and
            // acting on both edges would fire twice per tap. Long-press and
            // chords have the events they need waiting when we want them.
            guard pressed else { return }
            focusPane(index)
        case .deviceError(let message):
            // `ERR fatal …` is the firmware's dying words before it reboots
            // itself, and the console port carrying the real traceback is one
            // nobody reads. This line is the only account of what happened
            // that survives the reset.
            if message.hasPrefix("fatal") {
                logger.error("MacroPad firmware crashed: \(message, privacy: .public)")
            } else {
                logger.warning("MacroPad reported an error: \(message, privacy: .public)")
            }
        }
    }

    /// Marks the next `HELLO` as one Canopy caused, so the reset-loop counter
    /// ignores it.
    private func expectHostInitiatedHello() { helloIsHostInitiated = true }

    private func noteHello() {
        if helloIsHostInitiated {
            helloIsHostInitiated = false
            return
        }
        guard resetLoop.note(at: Date()) else { return }

        logger.error(
            """
            MacroPad reset loop: \(Self.resetLoopThreshold, privacy: .public) reconnects in \
            \(Int(Self.resetLoopWindow), privacy: .public)s — the firmware is most likely \
            crashing and rebooting itself
            """
        )
        if case .session(let id)? = store.focusedPane?.content,
           let session = store.openSessions.first(where: { $0.id == id }) {
            // Longer than the default: this reports failing hardware, and the
            // default dwell is tuned for "Maximum 5 panes".
            session.statusBar.showHint("MacroPad keeps restarting", forSeconds: 6)
        } else {
            // The status bar lives inside a session pane, so there is nowhere
            // to put this when the focused pane is a launcher or there are no
            // panes. Say that it was dropped rather than leaving "we warned
            // the user" and "we couldn't" looking identical.
            logger.notice("MacroPad reset-loop hint suppressed: the focused pane hosts no session")
        }
    }

    /// Zero is a legitimate count, not a failure: the firmware reports
    /// `HELLO <ver> 0` when it is running but the NeoKey board is not wired
    /// up (an unplugged Qwiic cable makes `board.STEMMA_I2C()` throw). It
    /// keeps the serial half alive on purpose so that state is
    /// distinguishable from a board that failed to boot — so throwing the
    /// distinction away here would waste what the firmware paid for it.
    /// Treating it as an error would also start a reconnect loop against a
    /// device that is answering perfectly well.
    ///
    /// Does **not** push. Both callers follow with `fullPush()`, and pushing
    /// here as well sent every key twice per `HELLO`.
    private func adoptIdentity(version: Int?, keyCount count: Int?) {
        // An absent version means firmware old enough to predate the field,
        // which is exactly the firmware without `S`. Defaulting it to 1 rather
        // than to the current version is what makes `command(for:at:)` degrade
        // instead of sending a verb the device will reject.
        let adopted = version ?? 1
        if adopted < Self.breatheProtocolVersion, protocolVersion != adopted {
            // The state that degrades hardest is `asking`, whose entire job is
            // to be the only key calling for a human. Silently becoming a
            // steady orange is not something to discover by staring at it.
            logger.notice("""
                MacroPad protocol \(version.map(String.init) ?? "unreported", privacy: .public) is below \
                \(Self.breatheProtocolVersion, privacy: .public): animated states degrade to steady colour, \
                so the asking key will not pulse
                """)
        }
        protocolVersion = adopted

        guard let count else {
            logger.warning("MacroPad identified without a key count; assuming \(Self.assumedKeyCount)")
            keyCount = nil
            return
        }
        guard count >= 0, count <= Self.maxKeyCount else {
            // Keep whatever was already adopted rather than falling back: a
            // single garbled digit on the wire should not drop a pad that has
            // already told us it has six keys down to the assumed four.
            logger.error("MacroPad reported an implausible key count (\(count)); keeping \(self.keyCount.map(String.init) ?? "the assumed count")")
            return
        }
        if count == 0, keyCount != 0 {
            logger.error("MacroPad reports 0 keys: the board is running but the NeoKey is not responding — check the Qwiic cable")
        }
        keyCount = count
    }

    private func focusPane(_ index: Int) {
        guard store.panes.indices.contains(index) else { return }
        // "Press it and you're there" means the app comes forward too — the
        // pad's reason to exist is being reachable while looking at something
        // else, so quietly moving focus behind another app's window would
        // deliver half the gesture.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { isCanopyWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        }
        store.setFocusedPaneIndex(index)
    }
}
