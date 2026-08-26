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
/// mapped to sidebar rows. The trigger is which pane the user last typed
/// into, and how recently — see `update`'s doc for why that replaced pane
/// focus plus app activation.
struct MacroPadUnreadTracker {
    struct Snapshot {
        let id: UUID
        let isThinking: Bool
        /// Which pane hosts this session, or nil when it isn't mapped to one.
        let paneIndex: Int?
    }

    /// How long a keystroke keeps a pane "recently typed in" for the purpose
    /// of clearing unread. Long enough to survive an ordinary thinking pause
    /// mid-message without the green mark reappearing under the user's own
    /// hands; short enough that a pane left focused overnight does not go on
    /// clearing itself the moment a turn happens to finish there.
    static let recentTypingThreshold: TimeInterval = 60

    private(set) var unread: Set<UUID> = []
    private var wasThinking: [UUID: Bool] = [:]

    /// Clearing is driven by keystroke recency in a pane, not by whether
    /// Canopy is the frontmost app. The app-active rule this replaced
    /// conflated two different questions: "is Canopy the frontmost app" is
    /// not "is a human looking at the screen". Walk away from the Mac
    /// without switching apps and Canopy stays active, the pane you left
    /// stays focused, and a turn finishing there produced no green at all —
    /// the one case the pad exists for.
    ///
    /// Keystroke recency subsumes app activation rather than sitting beside
    /// it: a keystroke can only reach the frontmost app in the first place,
    /// so switching to another app lets `secondsSinceTyped` go stale on its
    /// own with nothing extra to track. `lastTypedPaneIndex` is stamped by a
    /// `.keyDown` monitor on the currently focused pane, and by a MacroPad
    /// key press on the pane it focuses — it is deliberately not read from
    /// `focusedPaneIndex` itself, because a pane can sit focused for hours
    /// with nobody at the keyboard, which is exactly the state the old rule
    /// could not tell apart from someone actually there.
    mutating func update(_ sessions: [Snapshot],
                         lastTypedPaneIndex: Int?,
                         secondsSinceTyped: TimeInterval) {
        let live = Set(sessions.map(\.id))
        unread.formIntersection(live)
        wasThinking = wasThinking.filter { live.contains($0.key) }

        for session in sessions {
            let finished = (wasThinking[session.id] ?? false) && !session.isThinking
            wasThinking[session.id] = session.isThinking
            if finished { unread.insert(session.id) }
        }

        // Clearing runs after marking, deliberately: a turn that ends in the
        // pane the user is actively typing in must never light up green. The
        // two-step ordering is what makes "finished while typing there" and
        // "finished elsewhere, then typed there" collapse to the same clean
        // state without a special case for either.
        guard let lastTypedPaneIndex, secondsSinceTyped <= Self.recentTypingThreshold else { return }
        for session in sessions where session.paneIndex == lastTypedPaneIndex {
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

/// The two-ended chord that puts the pad to sleep, kept as a pure value type
/// for the same reason as the two above: it is arithmetic over press
/// timestamps, and embedded in the controller a gesture that fires too eagerly
/// and one that never fires at all are indistinguishable without a pad in your
/// hands.
///
/// The gesture is the two OUTERMOST keys held together — on any pad wider
/// than two they are not adjacent, which is what makes them hard to strike
/// simultaneously by accident. (An earlier draft also claimed they are not the
/// keys in constant use. They are: key 0 is pane 1.) That non-adjacency is why
/// `minimumKeyCount` is 3 and not 2 — at two keys the "ends" are the only
/// adjacent pair, so the one property the gesture rests on is void exactly
/// there.
///
/// The rule is "both ends down", NOT "both ends and nothing else": a palm or a
/// sleeve across the whole board satisfies it. Tightening to exactly two keys
/// would also reject a chord made with a stray middle finger, which is the
/// likelier accident, and waking costs one press — so the tolerant reading is
/// deliberate rather than overlooked.
///
/// It owns `keyCount` rather than taking it per call. That is not tidiness:
/// the controller arms a timer now and evaluates the hold a second later, and
/// a count arriving in between (a `PONG` reporting a different width) would
/// otherwise move the ends *underneath a hold in progress* — six keys held at
/// 0/3/5 become a satisfied chord the moment the pad claims to have four.
/// Owning the count puts that state out of reach of this type's API: the
/// geometry and the presses measured under it change together, or not at all.
/// (Out of reach, not unrepresentable — the two stored properties are kept
/// coherent by every mutating member agreeing to, not by construction.)
struct MacroPadSleepChord {
    /// How long both ends must be held. Chosen at the pad, not at the desk:
    /// the first build used 2 s and read as waiting for a machine to make up
    /// its mind, so it was retuned to 1 s on hardware. Still far past any
    /// two-handed fumble — the ends are not a pair a hand crosses by accident,
    /// so this duration confirms intent rather than filtering noise.
    static let holdDuration: TimeInterval = 1
    /// Below this there is no gesture at all — see the type's doc for why the
    /// floor is 3 rather than 2. A pad that has not reported a count yet is
    /// modelled as nil and lands here too. Zero no longer means "board up,
    /// NeoKey unwired": `code.py` fixes `NUM_KEYS` at module scope and says so
    /// in as many words, so an unwired NeoKey now reports the full count plus
    /// `ERR i2c …`. Elsewhere in this file and in CLAUDE.md zero is still
    /// described as that hardware state — pre-existing firmware rot, worth one
    /// sweep, not this change's to make.
    static let minimumKeyCount = 3

    private var keyCount: Int?
    private var pressedSince: [Int: Date] = [:]

    /// Adopts a new width and drops every press measured under the old one.
    /// A timestamp taken on a six-key pad means nothing on a four-key one,
    /// where the ends are different keys.
    mutating func setKeyCount(_ count: Int?) {
        guard count != keyCount else { return }
        keyCount = count
        pressedSince.removeAll()
    }

    private var ends: (low: Int, high: Int)? {
        guard let keyCount, keyCount >= Self.minimumKeyCount else { return nil }
        return (0, keyCount - 1)
    }

    /// Out-of-range indices are dropped rather than recorded, so `pressedSince`
    /// cannot become the one place wire garbage accumulates without bound —
    /// the second door CLAUDE.md's "the same forgery can have two doors"
    /// learning is about. (`focusPane` bounds the same index against the PANE
    /// count, which is a different number and can be the larger of the two, so
    /// it was never a bound on this.) The guard is observable only through
    /// `trackedKeyCount`; without that the probe cannot tell it from its
    /// absence — measured, not assumed.
    mutating func note(index: Int, pressed: Bool, at now: Date) {
        guard let keyCount, index >= 0, index < keyCount else { return }
        // A press for a key already down means a release went missing (the
        // firmware only emits settled edges), and restarting that key's clock
        // is the conservative reading: it can only push the deadline later,
        // never earlier. The controller re-arms on the moved deadline — an
        // earlier revision did not, and a single lost release edge wedged the
        // gesture until the user let go.
        if pressed {
            pressedSince[index] = now
        } else {
            pressedSince.removeValue(forKey: index)
        }
    }

    mutating func reset() { pressedSince.removeAll() }

    /// How many keys are currently believed to be down. Exists so `note`'s
    /// range guard is observable at all: every other property of this type is
    /// read through `holdDeadline`, which by construction only ever looks at
    /// the two ends, so a recorded out-of-range press cannot move it and the
    /// guard was measurably indistinguishable from its own absence.
    ///
    /// "Believed" is the honest word: a lost release edge on a MIDDLE key
    /// leaves an entry until the next `reset()` or width change. Nothing reads
    /// it as key state, and nothing should.
    var trackedKeyCount: Int { pressedSince.count }

    /// nil when the chord is not held; otherwise the instant the hold
    /// completes. One accessor rather than an `isArmed` / `isSatisfied` pair,
    /// because the pair let a caller ask the wrong one — `isSatisfied` at arm
    /// time is always false, `isArmed` at fire time drops the duration rule —
    /// and because a deadline is what the controller actually needs to
    /// schedule against. It also retires a fudge constant: an interval derived
    /// from the deadline needs no padding against a re-measurement rounding
    /// error, the way a fixed `holdDuration + slack` did. It can still arrive
    /// EARLY in wall-clock terms if the clock steps backwards after the timer
    /// is scheduled, which is exactly what the fire body's `deadline <= Date()`
    /// check is for — do not read this paragraph as licence to delete it.
    ///
    /// Measured from whichever end arrived **second**: resting a thumb on one
    /// end all evening must not shorten the gesture to a single tap on the
    /// other.
    var holdDeadline: Date? {
        guard let ends,
              let low = pressedSince[ends.low],
              let high = pressedSince[ends.high]
        else { return nil }
        return max(low, high).addingTimeInterval(Self.holdDuration)
    }
}

/// What the controller should do about the sleep-chord timer once the hold's
/// deadline has been recomputed. Extracted as a pure decision for the same
/// reason as `MacroPadController.effectiveBrightness`: inlined in the timer
/// body it was unreachable from the probe — not because it needs a `Timer`,
/// but because it sat behind one.
///
/// It is honest about what that buys. Pinning this function does NOT pin that
/// the controller consults it; restoring the one-shot behaviour that wedged
/// the gesture would still leave every assertion green. What it does pin is
/// the rule the wedge broke — a deadline that moved must be re-aimed, not
/// dropped — and the `force` case below, which is the one a plausible tidy-up
/// would silently break.
enum MacroPadSleepChordTimerAction: Equatable {
    /// The deadline did not move; a hold in progress keeps its timer rather
    /// than being restarted by unrelated key traffic.
    case leaveAlone
    case retire
    case aim(Date)

    /// `force` exists to remove an ordering dependency, not to add a mode —
    /// and the dependency is positional, not a nil comparison. As the fire
    /// body stands it clears its mirror before re-aiming, so `current` is nil
    /// against a non-nil `desired` and it would arm even without `force`. Move
    /// those two clears BELOW the guards — "clear only what we consumed", a
    /// tidy-up nothing in the file argues against — and `current` holds the
    /// same deadline `desired` does, `leaveAlone` wins, nothing is armed, and
    /// both ends are still held with no event left to wake the gesture. That
    /// is the round-1 wedge, restored by a refactor that looks like cleanup.
    static func next(current: Date?, desired: Date?, force: Bool) -> Self {
        if !force, desired == current { return .leaveAlone }
        guard let desired else { return .retire }
        return .aim(desired)
    }
}

/// Binds Canopy's session state to the MacroPad: pane activity out as LED
/// colors, key presses back in as pane focus.
///
/// Mapping is **pane index → key index**, which is Cmd+1..9's meaning, not
/// Cmd+Ctrl+1..9's. Panes cap at 6 (`SessionStore.paneAbsoluteCap`), which is
/// what the 6-key pad covers, so every pane now reaches a key. A narrower pad
/// covers a prefix and the keys past `panes.count` are blanked rather than
/// skipped. Nothing here hardcodes a width — the count comes off the wire in
/// `HELLO`.
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
    /// Where manual sleep is remembered. It is a state the user put the pad
    /// into rather than a preference, so it stays out of `CanopySettings` and
    /// its Settings pane — but it has to outlive the process all the same:
    /// the pad sits on a Mac that never sleeps, and a Canopy relaunch at 2am
    /// must not light the whole desk back up.
    private static let asleepDefaultsKey = "canopy.macroPadAsleep"

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
    /// and source-selector changes are excluded explicitly — otherwise
    /// flipping the switch three times would tell the user their hardware is
    /// failing.
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

    /// Every write goes through `didSet` so the chord's geometry cannot lag
    /// the wire. `PONG` is the path that needs it: it reaches `adoptIdentity`
    /// without touching the chord, which is how a width change could land
    /// inside a hold in progress. (`HELLO` also cancels the chord explicitly.
    /// Whether that call is load-bearing was NOT established: every `HELLO`
    /// this side can reach follows a notified disconnect, which has already
    /// cleared everything. It is kept as defence against a device that ever
    /// re-`HELLO`s inside one connection, not because a path was measured.)
    private var keyCount: Int? {
        didSet {
            guard keyCount != oldValue else { return }
            let hadHold = chordDeadline != nil
            chord.setKeyCount(keyCount)
            // The guard above already established the count changed, so the
            // presses are always cleared and the deadline is always nil here;
            // this is what retires the timer aimed at the old one.
            updateSleepChordTimer()
            if hadHold {
                logger.notice("MacroPad sleep chord dropped: the pad reported a different key count mid-hold")
            }
        }
    }
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
    /// Manual sleep: the pad dark on a deliberate gesture, because macOS
    /// offers no signal for "the display at that desk was switched off at its
    /// own power button" — see issue #147 for the alternatives that were
    /// measured and rejected.
    private var isAsleep = UserDefaults.standard.bool(forKey: MacroPadController.asleepDefaultsKey)
    private var chord = MacroPadSleepChord()
    private var chordTimer: Timer?
    /// The deadline `chordTimer` is aimed at. Kept beside it so a key event
    /// that does not move the deadline — a middle key, a duplicate edge —
    /// leaves a hold in progress alone instead of restarting it.
    private var chordDeadline: Date?
    /// Bumped on every re-aim. A fired timer carries the generation it was
    /// scheduled under, which is how its body knows whether it is still the
    /// live one: `Timer` is not `Sendable`, so the identity itself cannot
    /// cross into the main-actor hop, and an `ObjectIdentifier` could be
    /// reused by a freshly allocated timer at the same address.
    private var chordTimerGeneration = 0
    private var states: [SessionActivity] = []
    private var tracker = MacroPadUnreadTracker()
    private var watchdogTimer: Timer?
    private var helloIsHostInitiated = false
    private var lastSource: MacroPadSource?
    /// The pane the user was last typing in, and when. Stamped by
    /// AppDelegate's `.keyDown` monitor (any keystroke into a Canopy window
    /// counts, regardless of which key — this is a presence signal, not a
    /// content one) and by `focusPane` (answering the pad is itself "I am
    /// here, in this pane"). `refresh()` folds both into
    /// `MacroPadUnreadTracker.update` on every pass; nothing else reads them.
    private var lastTypedPaneIndex: Int?
    private var lastTypedAt: Date?

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
        device.setSource(settings.macroPadSource)
        expectHostInitiatedHello()
        device.start()
        startWatchdog()
        track()
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
        cancelSleepChord()
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
        // observation — including `settings.macroPadSource`, which is why
        // switching source takes effect without its own observer.
        let source = settings.macroPadSource
        let brightness = settings.macroPadBrightness
        let panes = store.panes
        let openSessions = store.openSessions

        if lastSource != source {
            // A switch Canopy performed will produce a `HELLO` that is not a
            // firmware reboot.
            if !source.isOff { expectHostInitiatedHello() }
            // See `shouldClearSleep`'s doc for why both conditions matter.
            if Self.shouldClearSleep(lastSource: lastSource, movingTo: source) { setAsleep(false) }
            lastSource = source
        }
        device.setSource(source)

        var paneIndexBySession: [UUID: Int] = [:]
        for (index, pane) in panes.enumerated() {
            if case .session(let id) = pane.content { paneIndexBySession[id] = index }
        }

        let secondsSinceTyped = lastTypedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        tracker.update(
            openSessions.map {
                MacroPadUnreadTracker.Snapshot(
                    id: $0.id,
                    isThinking: $0.isThinking,
                    paneIndex: paneIndexBySession[$0.id]
                )
            },
            lastTypedPaneIndex: lastTypedPaneIndex,
            secondsSinceTyped: secondsSinceTyped
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
    /// because the source selector is a third input and only `refresh()`
    /// observes it.
    ///
    /// `MacroPadStatus.publish` drops no-op writes, so the common case is
    /// free. A publish from outside a tracked pass costs one extra `refresh()`
    /// — see `publish`'s own doc for why the ones from inside do not.
    ///
    /// The mapping into `Keys` lives here rather than in `adoptIdentity`
    /// because it needs `isConnected` as well as the count.
    private func publishStatus() {
        guard !settings.macroPadSource.isOff else {
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

    /// Whether a key index off the wire is one this pad can actually have.
    /// Pure so the probe can reach it — the third extraction in this change
    /// for that reason, after `effectiveBrightness` and
    /// `MacroPadSleepChordTimerAction`, and for the same measured cause: with
    /// the check inlined in `handleKey`, deleting it left every assertion
    /// green.
    ///
    /// A count that cannot discriminate accepts everything, and ZERO is such a
    /// count. Refusing every index because the pad claims no keys strands a
    /// sleeping pad exactly the way refusing because it named no width would
    /// — and waking is the one action that must never become impossible,
    /// because it is the only exit from a persisted dark state. (The current
    /// firmware cannot report zero at all: `NUM_KEYS` is fixed at module
    /// scope, so an unwired NeoKey now surfaces as the full count plus
    /// `ERR i2c …`. Zero therefore means wire garbage — a corrupted `PONG`
    /// — which is precisely when guessing is worst.)
    static func acceptsKey(index: Int, keyCount: Int?) -> Bool {
        guard let keyCount, keyCount > 0 else { return true }
        return index >= 0 && index < keyCount
    }

    /// Sleep's override of the brightness setting, as a pure function so the
    /// probe can reach it. Three promises ride on this one expression — the
    /// pad goes dark on the gesture, stays dark through a reconnect, and stays
    /// dark through a relaunch — but only the first is testable here; the
    /// other two live in `applyBrightness`'s cache and in the `UserDefaults`
    /// read, neither of which the probe can drive.
    static func effectiveBrightness(percent: Int, isAsleep: Bool) -> Int {
        isAsleep ? 0 : min(100, max(0, percent))
    }

    /// Whether moving to `source` should clear manual sleep.
    ///
    /// Two conditions, both required, not one: `!source.isOff` is the
    /// newer-verb-wins rule (switching source is "I am using this pad now";
    /// the sleep chord is "go dark", and the more specific one should win).
    /// `lastSource != nil` is what stops a fresh launch from clobbering a
    /// sleep set before quitting — at launch `refresh()` runs before the
    /// user has touched anything, so evaluating `!source.isOff` alone would
    /// immediately un-sleep a pad the user put to sleep on purpose. Pure and
    /// static so the probe can reach both halves together — `setAsleep` is
    /// private and needs a live controller.
    static func shouldClearSleep(lastSource: MacroPadSource?, movingTo source: MacroPadSource) -> Bool {
        lastSource != nil && !source.isOff
    }

    /// Written as a clamp rather than an early `return` on purpose: a
    /// `guard !isAsleep else { return }` here would send **nothing** while
    /// asleep, so the pad would never darken in the first place, and issue
    /// #147 had to bolt a second guard onto the `HELLO` path to compensate.
    /// The clamp is one mechanism instead of two — the cache holds 0, and
    /// `fullPush()`, which drops the cache, re-asserts `B 0` by itself.
    ///
    /// That re-assert is load-bearing because the firmware resets brightness
    /// to its own default whenever the host disconnects. From `code.py`, in
    /// the `was_connected and not connected` branch:
    ///
    /// > Brightness goes back to the default for the same reason -- the next
    /// > host should not inherit a `B 5` the last one left behind.
    ///
    /// `DEFAULT_BRIGHTNESS = 0.6`, i.e. `B 60`. The same branch calls
    /// `all_off()` first, so a replug arrives *blanked* at 60% rather than
    /// lit — what would light the desk is the colours `fullPush` is about to
    /// send. That is also why `refresh()` calls this BEFORE `pushStates()`,
    /// an ordering the whole argument depends on and which is documented
    /// nowhere else.
    ///
    /// Waking sends whatever the slider says *now* — not the `B <previous>`
    /// the issue proposed — because the live setting is read on every
    /// `refresh()` and never snapshotted.
    private func applyBrightness(_ percent: Int) {
        guard isConnected else { return }
        let clamped = Self.effectiveBrightness(percent: percent, isAsleep: isAsleep)
        guard lastBrightness != clamped else { return }
        lastBrightness = clamped
        device.send(.brightness(percent: clamped))
    }

    /// `B 0` and back, and deliberately nothing else.
    ///
    /// `R` — or blanking each key — is the obvious move and is wrong here, for
    /// the reason `fullPush()` records as the *cost* of the `R` it used to
    /// send (its refusal rests on separate `NUM_KEYS` evidence, which is about
    /// stranded keys, not phases): blanking makes every key steady, so
    /// re-pulsing on wake restarts every phase together and puts `asking`'s
    /// deep breath in lockstep with `working`'s shallow one. What that costs
    /// is the DE-PHASING, not the ladder: `set_pulse` restarts a key's phase
    /// only when a steady key begins to pulse and never rewrites floors, so
    /// `asking` would still breathe deeper than `working` — it would just do
    /// it in time with everything else, and the keys would stop drifting apart
    /// on their own the way `MacroPadCommand.breathe` describes. (`fullPush`'s
    /// doc calls the same loss "collapsing the amplitude ladder"; measured
    /// against the firmware that names the wrong casualty, but it is
    /// pre-existing text and not this change's to rewrite.)
    /// Brightness is a plain multiply in the firmware, so zero scales the
    /// output to black without touching any key's colour, floor, period or
    /// phase — and wake is then one command, no re-push, no phase disturbed.
    private func setAsleep(_ asleep: Bool) {
        guard isAsleep != asleep else { return }
        isAsleep = asleep
        UserDefaults.standard.set(asleep, forKey: Self.asleepDefaultsKey)
        logger.notice("MacroPad manual sleep: \(asleep ? "asleep" : "awake", privacy: .public)")
        applyBrightness(settings.macroPadBrightness)
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
            // Very nearly redundant with `keyCount = nil` below, which
            // clears the press map through the `didSet`. Kept because the two
            // are not identical — this also drops any partial state before
            // the count is forgotten, and it keeps the line independent of
            // the observer's implementation.
            cancelSleepChord()
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
            // `HELLO` voids every cache of the device's state, and a map of
            // which keys are currently down is one — the same rule `fullPush`
            // follows for the colour and brightness caches.
            cancelSleepChord()
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
            handleKey(index: index, pressed: pressed)
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
            // default dwell is tuned for the one-line cap-reached hint.
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

    /// Release edges reach the chord and stop there: press-to-focus is the
    /// whole gesture, and acting on both edges would fire twice per tap. They
    /// are no longer dropped at the top because a release is exactly what
    /// cancels a half-made chord.
    private func handleKey(index: Int, pressed: Bool) {
        // One bound for every door. `MacroPadEvent.parse` rejects only a
        // negative index (deliberately — see the forged-`K` learning),
        // `focusPane` bounds against the PANE count, and the chord bounds
        // against the key count; the wake path below had no bound at all, so a
        // forged `K 9999 1` could relight a pad that was deliberately dark.
        //
        // `notice`, not `debug`: this records a decision to refuse input the
        // user may be physically producing, and it is the only line that
        // separates "the pad is narrower than you think" from "the subsystem
        // is broken". `debug` lives in a ring buffer and is gone by the time
        // anyone looks. An out-of-range index should be a never-event, so the
        // volume argument does not apply.
        guard Self.acceptsKey(index: index, keyCount: keyCount) else {
            logger.notice("MacroPad ignoring key \(index, privacy: .public): the pad reported \(self.keyCount ?? -1, privacy: .public) keys")
            return
        }
        guard !isAsleep else {
            // Any press wakes, and that press is swallowed: the first touch
            // after a night asleep is the user reaching for the light switch,
            // not for a pane.
            //
            // It is deliberately NOT recorded in the chord either. Waking is
            // most naturally attempted with the same both-ends grab that put
            // the pad down, and a chord that counted the waking press would
            // then re-sleep it a second later — the gesture would toggle twice
            // and settle back where it started. The cost is that an end key
            // held through the wake does not count toward the next chord until
            // it is lifted, which is the cheaper of the two surprises.
            guard pressed else { return }
            cancelSleepChord()
            setAsleep(false)
            return
        }
        chord.note(index: index, pressed: pressed, at: Date())
        updateSleepChordTimer()
        guard pressed else { return }
        // Both presses of the chord focus their panes on the way in, and
        // `focusPane` is not a quiet reassignment: it calls
        // `NSApp.activate(ignoringOtherApps:)`, orders the window front, and
        // clears that pane's unread marker. Issue #147 accepted the focus
        // change; what it understated is that the app comes forward, and that
        // "nobody is in front of it" is the one thing this gesture cannot
        // assume — it is performed by a person at the desk.
        //
        // Exempting only the press that COMPLETES the chord was tried and
        // REMOVED. It bought nothing measurable: the first end has already
        // activated the app and cleared its own pane's unread by then, so both
        // named harms had already happened, and the exemption additionally
        // leaked on a duplicate press of a held end — the lost-release path
        // this file spends a timer on. A real fix defers END-key presses to
        // their release edge, costing immediacy on two keys rather than all
        // six. That is a behaviour change and belongs to a decision, not to a
        // review round.
        focusPane(index)
    }

    /// Arms, re-aims, or retires the hold timer. The watchdog cannot carry
    /// this check the way issue #147 proposed: it ticks every
    /// `watchdogInterval` seconds, and sampling a `holdDuration` window that
    /// coarsely does not make the gesture slower, it makes it *missed* — the
    /// tick lands outside the hold almost every time.
    ///
    /// `force` is passed by the fire body; see
    /// `MacroPadSleepChordTimerAction.next` for why it is not a mode.
    private func updateSleepChordTimer(force: Bool = false) {
        switch MacroPadSleepChordTimerAction.next(
            current: chordDeadline, desired: chord.holdDeadline, force: force
        ) {
        case .leaveAlone:
            return
        case .retire:
            chordTimer?.invalidate()
            chordTimer = nil
            chordDeadline = nil
            // Bumped here as well as in `cancelSleepChord`, so "the generation
            // moved" means "no fire scheduled before now is still live" on
            // EVERY path. Without it a width change landing on a hold whose
            // timer had already fired let the stale body through to log a
            // released-ends cause that had not happened.
            chordTimerGeneration &+= 1
        case .aim(let deadline):
            chordTimer?.invalidate()
            chordDeadline = deadline
            chordTimerGeneration &+= 1
            let generation = chordTimerGeneration
            // `[weak self]` on the OUTER block, for the reason spelled out in
            // `startWatchdog`.
            let timer = Timer.scheduledTimer(
                withTimeInterval: max(0, deadline.timeIntervalSinceNow),
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    // The hop to the main actor is not ordered against the
                    // device queue's own hop, so a fresh timer can already
                    // have replaced this one by the time the body runs. The
                    // generation says whether this fire is still the live one.
                    //
                    // Every path that ends a hold now bumps it — `.retire`
                    // and `cancelSleepChord` alike — so this guard alone is
                    // enough to reject a fire scheduled before that. The
                    // re-reads below are still not decoration: they are what
                    // catches a release that lands in the window between this
                    // timer firing and this body draining, which no
                    // generation could see.
                    guard let self, self.chordTimerGeneration == generation else { return }
                    self.chordTimer = nil
                    self.chordDeadline = nil
                    guard let deadline = self.chord.holdDeadline else {
                        // Report the observation, not a cause: "released"
                        // is only the usual reason both ends stopped being
                        // held, and the code cannot tell it from a width
                        // change or a cancel. Abandoning is deliberate —
                        // ambiguity resolves to "do not sleep" — but at the
                        // pad it is indistinguishable from "I did not hold it
                        // long enough", so it gets a line.
                        //
                        // That bias is a tendency, not a guarantee: if this
                        // body drains before a release that beat the deadline,
                        // both ends are still recorded and the pad sleeps. The
                        // exact claim is that whenever the release wins the
                        // race, re-deriving refuses — where latching the
                        // satisfaction at fire time would sleep either way.
                        logger.notice("MacroPad sleep chord abandoned: the ends were not both held when the timer drained")
                        return
                    }
                    guard deadline <= Date() else {
                        // Reachable only through a backward wall-clock step: a
                        // re-press moves the deadline through
                        // `updateSleepChordTimer`, which bumps the generation,
                        // so that fire is already gone three lines above.
                        // Re-aim rather than drop — both ends are still down
                        // and nothing else would wake the gesture.
                        self.updateSleepChordTimer(force: true)
                        return
                    }
                    self.setAsleep(true)
                    // Belt and braces: `handleKey`'s sleep guard drops the
                    // release edges that follow, and the wake path calls
                    // `cancelSleepChord()` anyway.
                    self.chord.reset()
                }
            }
            // `.common` for the same reason as the watchdog: menu tracking and
            // live resize suspend the default mode.
            RunLoop.main.add(timer, forMode: .common)
            chordTimer = timer
        }
    }

    /// Bumps the generation as well as invalidating, so a fire whose `Timer`
    /// block already ran cannot pass the guard in its deferred body. Without
    /// it the cancel paths are correct only because `chord.reset()` happens to
    /// live here too — a coupling between this function and a value type that
    /// nothing states and a later edit would not preserve.
    private func cancelSleepChord() {
        chordTimer?.invalidate()
        chordTimer = nil
        chordDeadline = nil
        chordTimerGeneration &+= 1
        chord.reset()
    }

    /// Records "the user is here, working in this pane" and forces an
    /// immediate `refresh()` so the recency change clears unread in the same
    /// pass that stamped it — Observation would otherwise wait for some
    /// unrelated `SessionStore`/`CanopySettings` mutation to re-run the
    /// tracked closure, and a keystroke touches neither. Called from
    /// AppDelegate's `.keyDown` monitor with the currently focused pane, and
    /// from `focusPane` with the pane a MacroPad key press just brought
    /// forward.
    func noteInteraction(paneIndex: Int) {
        lastTypedPaneIndex = paneIndex
        lastTypedAt = Date()
        refresh()
    }

    private func focusPane(_ index: Int) {
        guard store.panes.indices.contains(index) else { return }
        noteInteraction(paneIndex: index)
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
