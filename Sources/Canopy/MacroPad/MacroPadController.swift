import AppKit
import CoreGraphics
import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MacroPad")


/// Which session was last acted on, and the act's place in a monotonic
/// order — one value because they are one fact, and a value type because the
/// alternative is untestable. As two stored properties on the controller,
/// deleting the counter's increment left the probe at a full green while the
/// feature was totally dead: every generation would be 0, `0 > 0` is false,
/// and nothing would ever clear again. That mutation now fails.
struct InteractionStamp: Equatable {
    private(set) var sessionId: UUID?
    private(set) var seq: UInt64 = 0

    /// `&+=` because 2^64 interactions is unreachable — that, not the cost of
    /// a trap, is why wrapping is safe. A wrap would not renumber gracefully:
    /// it would drop below every outstanding mark at once and strand them all
    /// until the counter climbed back past them.
    mutating func stamp(_ id: UUID) {
        sessionId = id
        seq &+= 1
    }
}

/// Tracks which sessions have finished a turn with no deliberate act on
/// them since — a turn finishing in the pane the user is looking at is
/// marked too; focus is not an input to marking. Split out of
/// `MacroPadController` as a pure value type so the probe can exercise the
/// edge cases without a `SessionStore`, a window, or a device.
///
/// "Unread" has no counterpart in Canopy's own UI — it exists because the pad
/// answers a question the screen never had to: *did anything finish while I
/// wasn't looking?* With the pad mapped to panes, every mapped session is on
/// screen, so "not visible" can't be the trigger the way it could if the pad
/// mapped to sidebar rows. Clearing it answers four questions — three
/// independent signals plus an ordering constraint; see `update`'s doc for
/// why none of them can be derived from the rest.
struct MacroPadUnreadTracker {
    struct Snapshot {
        let id: UUID
        let isThinking: Bool
    }

    /// How long ago the most recent presence signal — OS-level input on any
    /// device, OR a MacroPad key press, whichever is more recent — may have
    /// happened for the user to still count as present. This is deliberately
    /// not scoped to a pane or to typing: it answers "is anyone at the Mac at
    /// all", which a keystroke in one pane cannot answer about the other 59
    /// seconds after it, and OS input alone cannot answer for a press on a
    /// device with no HID interface. Short enough that a pane left focused
    /// overnight does not go on clearing itself; long enough to survive an
    /// ordinary reading pause with nothing touched, which is not the same as
    /// having left.
    static let presenceThreshold: TimeInterval = 30

    private(set) var unread: Set<UUID> = []
    private var wasThinking: [UUID: Bool] = [:]

    /// The interaction generation in force when each mark was created. It
    /// supplies the AFTER in "a deliberate act on that pane, AFTER this turn
    /// finished"; `lastInteractedSessionId` supplies the *which*.
    ///
    /// Without it, the act of sending a prompt cleared the completion of the
    /// very turn it started: `lastInteractedSessionId` is stamped when the
    /// user types, and a turn that finishes inside
    /// `presenceThreshold` of that keystroke satisfied attribution,
    /// presence and activation all at once — so the mark was inserted and
    /// removed inside one `update`. Measured on hardware 2026-08-27: prompt
    /// at t=0, finish at t=11 s — the row is quoted on `logUnreadDecision`, which is also where the caveat about its now-obsolete format lives. The
    /// bound was never "turns shorter than the threshold" — presence is reset
    /// by ANY input anywhere on the Mac, so the old rule also swallowed
    /// arbitrarily long turns whose finish landed within `presenceThreshold`
    /// of the user touching anything, while that session was still the
    /// last-interacted one and Canopy was frontmost.
    ///
    /// The accepted cost of the new rule, stated so the next round does not
    /// rediscover it as a bug and swing back: a turn that finishes under the
    /// user's eyes DOES light up, and stays lit until they click, type, or
    /// press its key. Reading is not an act this can see.
    private var markSeq: [UUID: UInt64] = [:]

    /// What one `update` actually did, as distinct from what the set looks
    /// like afterwards. The two are not the same and the difference is the
    /// bug this file exists to catch: a mark inserted and cleared inside the
    /// SAME call leaves `unread` byte-identical to an idle refresh, so a
    /// before/after diff cannot see it — which is precisely how the reported
    /// regression stayed invisible until a human who knew a turn had just
    /// ended read the log.
    ///
    /// `marked` and `cleared` both containing an id is that regression's
    /// signature — and under the current guard it is provably EMPTY, since a
    /// generation recorded one statement earlier can never be exceeded. Read
    /// it as a tripwire, not a live diagnostic: it fires only if someone
    /// reorders clear-before-mark or relaxes the comparison to `>=`. An empty
    /// pair is not evidence the mechanism ran.
    struct Outcome: Equatable {
        var marked: Set<UUID> = []
        var cleared: Set<UUID> = []
    }

    /// Clearing answers four questions. Three are independent signals; the
    /// fourth is an ordering constraint over the same input as the first,
    /// which is why counting disjoint signals found three and only hardware
    /// found the fourth. Two prior rules each answered one of the three;
    /// an earlier attempt answered two and, on a false argument that the
    /// third was implied by the second, dropped it.
    ///
    /// | Question | Signal |
    /// | --- | --- |
    /// | *Which* session was the user with? | interaction — typed into its pane, clicked it, focused it, or pressed its MacroPad key |
    /// | Did that act come **after** this turn finished? | `interactionSeq` against `markSeq` |
    /// | Is a human **at the machine** at all? | presence — the more recent of OS-level input (any device, any app) and a MacroPad key press |
    /// | Is that human **looking at Canopy**? | app activation |
    ///
    /// The second row is the one this file learned last, and it is not a
    /// refinement of the first: attribution says *which* pane an act was
    /// aimed at and says nothing about *when*, so on its own it let the
    /// prompt-sending keystroke clear the completion of its own turn. See
    /// `markSeq`.
    ///
    /// None of the three SIGNALS is derivable from the others, and all four
    /// combinations of presence × activation behave differently. The list
    /// below enumerates those two only; every line of it additionally
    /// requires the ordering row above:
    ///
    /// - Canopy frontmost, presence recent → using Canopy → clear
    /// - Canopy frontmost, presence stale → walked away with Canopy still
    ///   up → do NOT clear (the original bug — pane focus alone, or
    ///   `isAppActive` alone, both read this as "here")
    /// - Canopy backgrounded, presence recent → working in another app →
    ///   do NOT clear (this branch's regression: `secondsSincePresence` is
    ///   `CGEventSource`'s SYSTEM-WIDE idle time, reset by input to ANY
    ///   app, so typing in a different app kept it "recent" and cleared a
    ///   mark on a session nobody was looking at)
    /// - Canopy backgrounded, presence stale → gone → do NOT clear
    ///
    /// A prior version answered only the first — "typed into this pane
    /// within the last 60 s" — on the theory that a keystroke can only reach
    /// the frontmost app, so leaving lets the recency go stale on its own.
    /// It doesn't: the common way to walk away is type a message, hit enter,
    /// and get up, and a turn finishing 40 s later still read as "typed
    /// recently" — the bug it was meant to fix, just bounded to a minute
    /// instead of unbounded.
    ///
    /// Splitting attribution from presence fixed that, and this branch then
    /// argued "presence subsumes app activation, since input only reaches
    /// the frontmost app" and deleted `isAppActive`. That is true of a
    /// keystroke delivered to one of Canopy's own windows — the mechanism
    /// behind `lastInteractedSessionId` — but false of `secondsSincePresence`
    /// itself, which measures input to the WHOLE SYSTEM, not to Canopy: type
    /// into session A, switch to another app, keep typing there, and
    /// presence never goes stale while A's turn finishes and clears itself —
    /// exactly the case the LED exists to report. Presence answers "is a
    /// human at the machine", which is necessary but not sufficient for "is
    /// that human looking at Canopy" — the same shape of gap that makes
    /// attribution alone insufficient for presence. Each of the three
    /// signals is measured from its own, disjoint input (a keystroke's
    /// destination window, `CGEventSource` plus the pad's own press
    /// timestamp, and `NSApplication`'s activation notifications), so none
    /// can stand in for another. That argument does NOT extend to the
    /// ordering condition, which reads the SAME events as attribution and
    /// adds only *when* — which is why three disjoint inputs yielded three
    /// conditions and the fourth had to be found on hardware.
    ///
    /// `isAppActive` is not read live here — pure value types don't ask
    /// AppKit anything. `MacroPadController` mirrors `NSApp.isActive` into a
    /// stored property via `didBecomeActive` / `didResignActive` observers
    /// and passes the snapshot in, because AppKit's activation is a
    /// notification, not a value `refresh()`'s tracked closure could read to
    /// become a dependency of it.
    ///
    /// `lastInteractedSessionId` is stamped by a `.keyDown` monitor on the
    /// currently focused pane's session, by a click in a pane's body, by a
    /// click on its sidebar row, by `MacroPadController.refresh` on any
    /// change to which session occupies the focused pane (covers focus
    /// changes from any source — Cmd+1..9, Cmd+Opt+arrow, Cmd+Shift+[/]
    /// cycling), and by a MacroPad key press. The two click routes are
    /// explicit because both can leave the focused session UNCHANGED, which
    /// is exactly when they matter — see `noteInteraction`. It is keyed on
    /// the session's `UUID`, not a pane index, so a pane closing and a
    /// different session later landing at the same index cannot inherit a
    /// stale attribution.
    @discardableResult
    mutating func update(_ sessions: [Snapshot],
                         lastInteractedSessionId: UUID?,
                         interactionSeq: UInt64,
                         secondsSincePresence: TimeInterval,
                         isAppActive: Bool) -> Outcome {
        var outcome = Outcome()
        let live = Set(sessions.map(\.id))
        unread.formIntersection(live)
        wasThinking = wasThinking.filter { live.contains($0.key) }
        markSeq = markSeq.filter { live.contains($0.key) }

        for session in sessions {
            let finished = (wasThinking[session.id] ?? false) && !session.isThinking
            wasThinking[session.id] = session.isThinking
            if finished {
                // `marked` reports the ARMING, not the set insertion, and
                // the difference is not cosmetic: a second turn finishing
                // while the first is still unacknowledged leaves `unread`
                // unchanged but advances `markSeq`, which INVALIDATES any act
                // that had already happened. (A is marked at gen 10; the user
                // clicks it at 11 but the clear is refused because Canopy was
                // not yet frontmost; A finishes again and re-arms at 11, so
                // that click is now permanently insufficient.) Keyed on the
                // set transition, the log said nothing at the one moment a
                // reader would need it to.
                //
                // Known and deliberately not fixed: the generation recorded
                // is the one in force when the finish is OBSERVED, not when
                // it happened. `refresh()` is scheduled by `Observation`, so
                // an act landing in the gap — the user clicks a fraction of a
                // second after a turn ends, before the queued refresh runs —
                // bumps the counter first and is then refused by its own
                // mark. It fails SAFE (the LED stays lit; a second click
                // clears it) and the window is one main-actor turn.
                //
                // The obvious fix, marking at the generation in force at the
                // LAST refresh, was traced and rejected: it also flips the
                // case where focus ARRIVES at a pane in the same pass its
                // turn ends, which reviewers read as correctly staying lit,
                // and it edits the one comparison this file spent two rounds
                // pinning. Reported by two reviewers independently; recorded
                // here so the third does not have to re-derive it.
                unread.insert(session.id)
                outcome.marked.insert(session.id)
                markSeq[session.id] = interactionSeq
            }
        }

        // Clearing runs after marking so a mark created in this same call
        // is visible to the guard below — which then refuses it, because
        // `interactionSeq` cannot exceed a generation recorded one statement
        // ago. That refusal IS the feature: a turn that finishes while the
        // user is present lights up green and waits to be acknowledged,
        // rather than being cleared by the keystroke that started it.
        //
        // An earlier version claimed the opposite ("a turn that ends in the
        // session the user is actively present with must never light up
        // green") and cleared without regard to WHEN the act happened — the
        // other three clauses were already here, so do not go looking in the
        // history for a bare unconditional `unread.remove`. That is what made the
        // LED unusable for its whole purpose: any turn whose finish landed
        // within `presenceThreshold` of the user touching anything was marked
        // and unmarked inside one `update`, so walking away right after
        // sending a prompt — the exact gesture this file exists to serve —
        // produced nothing.
        //
        // The `markSeq` lookup replaces what used to be a bare
        // `unread.remove`, and subsumes its no-op case: a stale
        // `lastInteractedSessionId` whose session has closed was already
        // pruned from `markSeq`, so the guard fails there instead.
        guard let lastInteractedSessionId,
              let markedAtSeq = markSeq[lastInteractedSessionId],
              interactionSeq > markedAtSeq,
              secondsSincePresence <= Self.presenceThreshold,
              isAppActive
        else { return outcome }
        // `cleared` cannot under-report only because `markSeq.keys == unread`
        // holds by construction — written together above, nilled together
        // here, pruned together against `live`, cleared together in `reset()`.
        // Nothing enforces that; if it broke in the "generation with no mark"
        // direction this would consume a generation and report nothing, which
        // in this subsystem is the failure mode rather than a symptom of one.
        if unread.remove(lastInteractedSessionId) != nil {
            outcome.cleared.insert(lastInteractedSessionId)
        }
        markSeq[lastInteractedSessionId] = nil
        return outcome
    }

    /// The generation recorded when `id` was marked, or nil if it holds no
    /// mark. Exists only so `logUnreadDecision` can print the stored side of
    /// the ordering comparison; nothing decides anything from it.
    func markedGeneration(of id: UUID) -> UInt64? { markSeq[id] }

    /// Clears every map this type owns. `markSeq` is easy to forget here and
    /// was, for one commit: the direction that broke was the safe one (a
    /// generation with no mark only ever enables a no-op remove), but the
    /// other direction — a mark with no generation — makes that session
    /// unclearable for the life of the process, with nothing logged. There
    /// are no callers today; the point is that the first one inherits a
    /// consistent type rather than this omission.
    mutating func reset() {
        unread.removeAll()
        wasThinking.removeAll()
        markSeq.removeAll()
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
    /// Which session was last acted on, and the act's place in the order —
    /// one value because they are one fact, and because two stored properties
    /// let a stamp site advance one without the other. Read through
    /// `lastInteractedSessionId` / `interactionSeq` below; written only by
    /// `stampInteraction`.
    ///
    /// It answers *which* session, never *whether the user is still there*
    /// (that's `secondsSincePresence`, computed fresh in `refresh()` and not
    /// stored) — and, since the generation, *when* relative to a mark. The
    /// routes that stamp it are enumerated once, on `noteInteraction`; an
    /// earlier copy here listed three of the five and went stale the same
    /// commit that added the fourth.
    private var interaction = InteractionStamp()
    /// The session `refresh()` last saw occupying the focused pane. Compared
    /// against on every pass so a CHANGE — not the raw value — is what
    /// stamps `lastInteractedSessionId`: sitting on the same pane for hours
    /// must not read as a fresh interaction, but a sidebar click, Cmd+1..9,
    /// Cmd+Opt+arrow, or Cmd+Shift+[/] cycling the session shown in the
    /// focused pane all must. `nil` also covers "no session at the focused
    /// pane yet", so the very first real session landing there does count as
    /// a change — the boot-time no-op is harmless because nothing is unread
    /// yet at that point either.
    ///
    /// A CHANGE alone is not sufficient, though — only a necessary condition
    /// for stamping. A pane can become focused with nobody at the desk: a
    /// crashed or `.reconnectFailed` session's pane closes autonomously
    /// (`SessionStore.removePanesForClosedSession`), collapses the strip, and
    /// hands focus to whatever pane is left, which may host an unread
    /// session. Stamping attribution unconditionally on that event forged
    /// exactly the attribution this file exists to get right: presence,
    /// satisfied later by an ordinary touch anywhere on the Mac, would then
    /// clear a mark nobody ever looked at. `refresh()` therefore only stamps
    /// when `secondsSincePresence` is *already* within
    /// `MacroPadUnreadTracker.presenceThreshold` at the moment the change is
    /// observed — a real click or keypress satisfies that trivially (it is
    /// itself what invalidated the tracked closure or immediately preceded
    /// it), while a pane collapsing with nobody around does not.
    private var lastObservedFocusedSessionId: UUID?
    /// The last time a physical key on the pad was pressed — a presence
    /// signal, stamped in `handleKey` at the moment of the press itself. Only
    /// the sleep-wake press is exempt from calling `focusPane` (swallowed in
    /// `handleKey`'s sleep branch, see below); every other accepted press —
    /// chord presses included — DOES reach `focusPane`, since `handleKey`
    /// never gates it on whether a chord completed. `lastPadPressAt` still
    /// has to be stamped independently of that: `focusPane` only records
    /// attribution (via `noteInteraction`), never presence, so nothing else
    /// would notice a human touched the pad at all — least of all the
    /// sleep-wake press, which never reaches `focusPane` to record anything
    /// itself. This exists because the pad's firmware disables its USB HID
    /// interface on purpose (CLAUDE.md's "Serial (CDC), never HID"), so
    /// `CGEventSource` cannot see a press arriving over the pad's serial link
    /// at all. `refresh()` folds this and `CGEventSource`'s own idle reading
    /// together — whichever is more recent wins — into
    /// `secondsSincePresence`; nothing else reads it.
    ///
    /// Backed by `DispatchTime` (a monotonic uptime tick), not `Date`, so
    /// that `min`ing it against `CGEventSource`'s own monotonic reading in
    /// `refresh()` never mixes a wall clock with a monotonic one — an NTP
    /// step or a sleep/wake skew on a `Date`-based timestamp could otherwise
    /// make this term go negative and trivially satisfy presence.
    private var lastPadPressAt: DispatchTime?

    /// Weak, because the controller is owned by `AppDelegate` and SwiftUI
    /// views cannot reach it otherwise. `MacroPadStatus` covers what the UI
    /// needs to READ; this covers the one thing a view needs to TELL it —
    /// that a click happened on a row.
    ///
    /// Deliberately NOT `nonisolated(unsafe)`, which is where
    /// `SessionStore.shared` differs: that one is read from a raw `NSEvent`
    /// monitor closure with no static isolation, and this one only from a
    /// `View`, which infers `@MainActor` from `body`. Keeping the isolation
    /// means the compiler checks the next call site instead of this comment
    /// having to.
    static weak var shared: MacroPadController?

    /// Records one interaction: which session it was aimed at, and its place
    /// in the order. The two are halves of one fact and a mark is only
    /// clearable by a generation NEWER than its own, so a stamp site that
    /// moved the id without advancing the counter would silently reinstate
    /// the bug this whole rule exists to fix — attribution landing on a
    /// session whose mark predates the current generation, which then clears
    /// on the next refresh. Written once so that cannot be forgotten at a
    /// third call site; both existing ones go through here.
    private func stampInteraction(_ id: UUID) {
        interaction.stamp(id)
    }

    private var lastInteractedSessionId: UUID? { interaction.sessionId }

    /// Count of interactions — keystrokes, pane clicks, sidebar row clicks,
    /// pad presses and focus arrivals, not keystrokes alone. Its only job is
    /// ordering: a mark records the value in force when it was created, and
    /// only a strictly larger value may clear it. One user act can bump it
    /// twice (a click that also moves focus), which the strictly-greater
    /// comparison makes harmless. See `InteractionStamp` for the wrap.
    private var interactionSeq: UInt64 { interaction.seq }

    /// Dedup key of the last line emitted by `logUnreadDecision`, so an
    /// unchanged decision is not re-logged. It is the emitted line MINUS the
    /// generation, the mark's own generation, and the raw presence reading —
    /// see that method for why those three exclusions are load-bearing, and
    /// for why this subsystem logs at all.
    private var lastUnreadLogKey: String = ""
    /// Mirrors `NSApp.isActive`. Kept as stored state rather than read live
    /// because `refresh()` has to re-run when it changes, and AppKit's
    /// activation is a notification, not an observable property `refresh()`'s
    /// tracked closure could depend on directly. Answers the last of
    /// `MacroPadUnreadTracker.update`'s clearing questions — "is the
    /// present human looking at Canopy" — which neither attribution nor
    /// system-wide presence can answer (see that doc for the measured case
    /// where presence alone reads a backgrounded Canopy as "here").
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
        Self.shared = self
        device.setOutputHandler { [weak self] output in self?.handle(output) }
        device.setSource(settings.macroPadSource)
        expectHostInitiatedHello()
        device.start()
        startWatchdog()
        observeActivation()
        track()
    }

    /// The activation condition of `MacroPadUnreadTracker.update`'s rule.
    ///
    /// The explicit `refresh()` is required because activation mutates no
    /// `SessionStore` or `CanopySettings` property `refresh()`'s tracked
    /// closure reads, so without it nothing would notice the return until
    /// some unrelated change woke the tracked closure on its own — and
    /// `isAppActive` would then be stale in every decision taken in between.
    ///
    /// It does NOT clear anything by itself, and an earlier version of this
    /// doc claimed it did ("what makes returning to Canopy via Cmd+Tab clear
    /// a mark that was already eligible"). Since `markSeq`, clearing needs an
    /// act NEWER than the mark, and coming back to the app is not an act on
    /// any particular pane — `interactionSeq` is deliberately not bumped
    /// here. Cmd+Tab makes a mark eligible; a click, a keystroke or a pad
    /// press is what spends it.
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
        cancelSleepChord()
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

        // Presence has two sources, and the tracker gets whichever is more
        // recent. System-wide idle time, any input device — deliberately not
        // scoped to a pane or to typing. Exposes only elapsed time, not
        // event content, so it needs no TCC permission (verified: no prompt
        // on a sandboxless run, values increase monotonically while idle).
        // Not probe-reachable — it is a live read of the current process's
        // event stream, which no fixture can substitute for; see
        // `MacroPadUnreadTracker`'s probe coverage for what IS pinned here
        // (the two-source combination itself, via `effectivePresence`).
        let secondsSinceOSInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
        )
        if secondsSinceOSInput < 0 {
            // Never observed, and never clamped here — clamping would hide
            // exactly the anomaly this line exists to surface. A negative
            // reading would trivially satisfy presence below, reinstating
            // the bug this file fixes with nothing left to grep for.
            logger.notice("MacroPad presence: CGEventSource reported a negative idle time (\(secondsSinceOSInput, privacy: .public))")
        }
        // The pad's firmware disables its USB HID interface on purpose
        // (CLAUDE.md's "Serial (CDC), never HID") so `CGEventSource` cannot
        // see a key press — without this second source, walking up and
        // pressing the lit key would attribute correctly (`handleKey` stamps
        // `lastPadPressAt`) but never satisfy presence, and the LED would
        // stay lit under the user's own hand.
        let secondsSincePadPress: TimeInterval = lastPadPressAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
        } ?? .infinity
        let secondsSincePresence = Self.effectivePresence(
            secondsSinceOSInput: secondsSinceOSInput, secondsSincePadPress: secondsSincePadPress
        )

        // Reading `store.focusedPaneIndex` here is what makes it a dependency
        // of this tracked closure — a later write to it (a sidebar click, a
        // pane click, Cmd+1..9, Cmd+Opt+arrow, or a MacroPad key via
        // `focusPane`) invalidates the tracking and schedules the next
        // `refresh()` through `track()`'s `onChange`. Cmd+Shift+[/] cycling
        // does NOT write `focusedPaneIndex` — it swaps `panes[i].content`
        // through `openInFocusedPane`, so that dependency comes from reading
        // `panes` a few lines up instead. Comparing the SESSION at the
        // focused index (not the index itself) against what we saw last time
        // is what turns "focus moved" into "an interaction happened": both
        // mechanisms can change which session sits behind an unmoving
        // `focusedPaneIndex`, so an index-only comparison would miss either.
        //
        // This hook is attribution-only in what it's FOR — it never reads
        // presence to decide THAT something changed. But a pane can become
        // focused with no human involved at all (closing the focused pane's
        // session collapses the strip and moves focus onto whatever pane is
        // left, autonomously), so the stamp below is additionally gated on
        // `secondsSincePresence` already being within threshold at this
        // instant — see `lastObservedFocusedSessionId`'s doc for the failure
        // this closes. A real click or keypress satisfies that gate for
        // free, since it is what invalidated this tracked closure (or
        // immediately preceded it via `noteInteraction`'s explicit refresh).
        // Not probe-reachable — it needs a live `SessionStore` and
        // `Observation` tracking, neither of which the DEBUG probe drives.
        let focusedPaneIndex = store.focusedPaneIndex
        let focusedSessionId = Self.sessionId(atPaneIndex: focusedPaneIndex, in: panes)
        if focusedSessionId != lastObservedFocusedSessionId {
            lastObservedFocusedSessionId = focusedSessionId
            if let focusedSessionId, secondsSincePresence <= MacroPadUnreadTracker.presenceThreshold {
                stampInteraction(focusedSessionId)
            }
        }

        let outcome = tracker.update(
            openSessions.map {
                MacroPadUnreadTracker.Snapshot(id: $0.id, isThinking: $0.isThinking)
            },
            lastInteractedSessionId: lastInteractedSessionId,
            interactionSeq: interactionSeq,
            secondsSincePresence: secondsSincePresence,
            isAppActive: isAppActive
        )
        logUnreadDecision(secondsSincePresence: secondsSincePresence,
                          focusedSessionId: focusedSessionId,
                          thinking: openSessions.filter(\.isThinking).map(\.id),
                          outcome: outcome)

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

    /// Combines the two presence sources — OS-level idle time and time since
    /// the pad's own last key press — into the one reading
    /// `MacroPadUnreadTracker.update` gates clearing on. Pure and static so
    /// the probe can pin the actual DESIGN DECISION being tested: that
    /// presence has two sources and a pad press is one of them. Before this
    /// existed, the probe's "pad present" tests computed `min(...)` inline
    /// and handed the scalar straight to `update`, which could not fail if a
    /// future edit dropped the pad term from the real combination in
    /// `refresh()` — the tests exercised `min` the operation, not this
    /// function.
    static func effectivePresence(
        secondsSinceOSInput: TimeInterval, secondsSincePadPress: TimeInterval
    ) -> TimeInterval {
        min(secondsSinceOSInput, secondsSincePadPress)
    }

    /// Whether `noteInteraction` must run a full `refresh()`. Pure and static
    /// so the four combinations can be pinned: the argument for skipping is
    /// that a clear can only ever remove `lastInteractedSessionId`, which the
    /// caller just set to `id`, so nothing can change unless `id` itself is
    /// marked — and the DANGEROUS direction is tightening this further. Add a
    /// condition (an `isAppActive` test, a focused-pane check) and the
    /// acknowledging click stops triggering a refresh, so the mark burns
    /// until some unrelated observation happens to wake `refresh()`. That is
    /// the failure this whole file exists to remove, and before this was a
    /// function nothing stood between it and main.
    static func shouldRefresh(alreadyStamped: Bool, idIsUnread: Bool) -> Bool {
        !alreadyStamped || idIsUnread
    }

    /// Resolves the session occupying a pane index, or nil for an
    /// out-of-range index or a pane with no session (`.launcher`). Written
    /// once so the two call sites that used to hand-roll this bounds check —
    /// `refresh()`'s focus-change hook and `noteInteraction` — cannot drift
    /// out of step with each other, the same reason `PaneLayoutMetrics` is
    /// one shared function rather than one per caller.
    static func sessionId(atPaneIndex index: Int, in panes: [PaneSlot]) -> UUID? {
        guard panes.indices.contains(index), case .session(let id) = panes[index].content else { return nil }
        return id
    }

    /// Records every change to the unread OUTCOME — not to the reason behind
    /// it: the raw presence reading rides outside the dedup key, so which
    /// clause is currently refusing can change with no row. Exists because this
    /// subsystem's failure mode is silence: an LED that stays dark looks
    /// exactly like an LED with nothing to report, and no other line in the
    /// process distinguishes them. Three separate wrong rules shipped here
    /// (CLAUDE.md's MacroPad learnings carry the full ladder; `update`'s doc
    /// argues only the last two), and the one that survived longest was
    /// diagnosed only after this line was added by hand mid-session — it
    /// named the cause in a single row, `p=11 act=true int=A9C7 pre= post=`,
    /// after reasoning from the source had failed for the better part of an
    /// hour. That hand-added row predates today's fields, so do not grep a
    /// capture for its exact shape. Re-deriving it next time is the cost
    /// this line buys off.
    ///
    /// `notice`, not `info` or `debug`: the gesture being diagnosed is "walk
    /// away for minutes, come back and look", so the interesting rows are
    /// always older than the in-memory ring buffer those levels live in.
    /// Volume is bounded by emitting only on a CHANGE of the DECISION — an
    /// idle Canopy settles to silence, and an active turn produces a handful
    /// of rows. Not literally nothing: the first refresh always emits, and
    /// `act=` and `foc=` are in the key, so app switches and focus changes
    /// cost one row each even with nothing running. Which fields count as "the decision"
    /// is load-bearing rather than cosmetic; see the key below for the two
    /// that are excluded and what including them cost. Session ids are truncated to four characters: enough
    /// to tell panes apart in one capture, not enough to correlate a user
    /// across logs.
    private func logUnreadDecision(secondsSincePresence: TimeInterval,
                                   focusedSessionId: UUID?,
                                   thinking: [UUID],
                                   outcome: MacroPadUnreadTracker.Outcome) {
        func tag(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "-" }
        func tags(_ ids: some Collection<UUID>) -> String {
            ids.map { String($0.uuidString.prefix(4)) }.sorted().joined(separator: ",")
        }
        // Three fields deliberately ride along OUTSIDE the dedup key: `seq`,
        // which advances on every keystroke; `mark`, which moves with it; and
        // `p`, which ticks once a second. Keying on any of the three made the
        // guard unreachable exactly when
        // something was lit — `noteInteraction` refreshes per keystroke while
        // that pane's session is unread — turning "a handful of rows per
        // turn" into one persisted `notice` per character typed.
        //
        // `+`/`-` are the marks added and cleared BY THIS CALL, and they are
        // in the key. Nothing else in the line can show a mark inserted and
        // cleared inside one `update`: the set looks identical before and
        // after, which is exactly how the reported regression stayed
        // invisible until a human who knew a turn had just ended read the log.
        let key = [
            "act=\(isAppActive)",
            "int=\(tag(lastInteractedSessionId))",
            "foc=\(tag(focusedSessionId))",
            "think=\(tags(thinking))",
            "unread=\(tags(tracker.unread))",
            "+\(tags(outcome.marked))",
            "-\(tags(outcome.cleared))",
        ].joined(separator: " ")
        guard key != lastUnreadLogKey else { return }
        lastUnreadLogKey = key
        // `inf` rather than a numeric sentinel: a NEGATIVE reading is a real
        // anomaly this file logs separately and refuses to clamp, so a `-1`
        // here would be indistinguishable from it in a capture.
        // A NEGATIVE reading gets its own token rather than a number. Clamping
        // it to 0 — which an earlier version did, beside a comment claiming
        // this file "refuses to clamp" a negative — is the worst available
        // lie: 0 reads as "input one second ago", exactly the state a negative
        // reading counterfeits, in the one line built to surface it. NaN is
        // separated for the same reason: it is a different anomaly from "no
        // pad press ever recorded", which is what `inf` means. The upper clamp
        // stays and is a real `Int(Double)` trap guard, so `86400` means "a day
        // or more", not "exactly a day".
        let presence: String
        if secondsSincePresence.isNaN { presence = "nan" }
        else if secondsSincePresence < 0 { presence = "neg" }
        else if secondsSincePresence.isInfinite { presence = "inf" }
        else { presence = String(Int(min(86_400, secondsSincePresence.rounded()))) }
        // `mark` is the OTHER operand of the ordering comparison. `seq` alone
        // says which generation we are in and nothing about how far the mark
        // is from clearable, which left half of that clause unreadable — the
        // complaint that produced this field in the first place.
        let stored = lastInteractedSessionId.flatMap { tracker.markedGeneration(of: $0) }
        logger.notice("MacroPad unread: p=\(presence, privacy: .public) seq=\(self.interactionSeq, privacy: .public) mark=\(stored.map(String.init) ?? "-", privacy: .public) \(key, privacy: .public)")
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
        // A physical press is proof someone is at the desk regardless of
        // where it ends up attributed — the sleep-wake press below is
        // swallowed before it ever reaches `focusPane`, but every other
        // accepted press (chord presses included) DOES reach it, since
        // `handleKey` never gates `focusPane` on whether a chord completed.
        // Stamped here, not only alongside attribution in `focusPane`,
        // because `focusPane` only ever records attribution, never
        // presence — so the wake press, which never reaches `focusPane` at
        // all, would otherwise leave no trace that anyone was there. See
        // `lastPadPressAt`'s doc for why this exists at all (the pad has no
        // HID interface for `CGEventSource` to see).
        if pressed { lastPadPressAt = .now() }
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
    /// immediate `refresh()` so the change can clear unread in the same pass
    /// that stamped it — Observation would otherwise wait for some unrelated
    /// `SessionStore`/`CanopySettings` mutation to re-run the tracked
    /// closure, and neither a keystroke nor a MacroPad key press mutates
    /// anything `refresh()` reads on their own.
    ///
    /// Resolves the pane to its session at call time and stores only the
    /// `UUID` (`MacroPadUnreadTracker` is keyed on it, not on a pane index —
    /// see its doc for why a stored index goes stale). A `paneIndex` outside
    /// `store.panes` or a launcher pane with no session is a silent no-op.
    ///
    /// Called from four places. Three of them exist because `refresh()`'s own
    /// focus-change tracking (see `lastObservedFocusedSessionId`) cannot see
    /// them — the session at the focused pane does not change: AppDelegate's
    /// `.keyDown` monitor, for typing into an already-focused pane;
    /// `installPaneFocusClickMonitor`, for a click in an already-focused
    /// pane's body; and `focusPane`, for a MacroPad press on an
    /// already-focused pane. The fourth, the sidebar's row click, goes
    /// through `noteInteraction(sessionId:)` for the same reason in a
    /// different surface.
    ///
    /// The click monitor's call is deliberately UNCONDITIONAL rather than
    /// scoped to the same-pane case, so for a click that DOES move focus it
    /// duplicates what `refresh()`'s hook would do anyway — harmless under a
    /// strictly-greater comparison, the same trade `focusPane` documents
    /// below. An earlier version of this paragraph listed "plain pane click"
    /// among the routes that "need no call here"; acting on that would delete
    /// the call and reinstate the bug (`markSeq`) exists to fix.
    ///
    /// Still needing no call here: Cmd+1..9, Cmd+Opt+arrow, and Cmd+Shift+[/]
    /// cycling. `refresh()`'s focus hook stamps the ARRIVING session for all
    /// three. The `.keyDown` monitor also fires on them, but at key-down —
    /// before the command moves focus — so it attributes to the pane being
    /// LEFT; that is a harmless extra bump under the strictly-greater
    /// comparison, not the mechanism that covers them.
    func noteInteraction(paneIndex: Int) {
        guard let id = Self.sessionId(atPaneIndex: paneIndex, in: store.panes) else { return }
        noteInteraction(sessionId: id)
    }

    /// The same act, named by session rather than by pane, for callers that
    /// already hold an id — the sidebar, whose row is where the green dot the
    /// user is reacting to actually lives.
    ///
    /// Clicking the row of a session that ALREADY occupies the focused pane
    /// reaches neither of the two routes a mouse click can otherwise take:
    /// the pane-click monitor
    /// bails before the sidebar's x range, and `openInFocusedPane` takes its
    /// focus-only branch, so `refresh()`'s focus hook sees no session change.
    /// Four reviewers found that independently, and it is the same shape as
    /// the bug this file's generation rule exists to fix — an unmistakably
    /// deliberate act on a lit session that acknowledges nothing.
    ///
    /// Deliberately called from the sidebar's click handler and NOT from
    /// `SessionStore.openInFocusedPane`, which is also reached by routes with
    /// no human behind them (a closing pane collapsing focus onto its
    /// neighbour). A store method cannot tell those apart; a click handler
    /// does not have to.
    func noteInteraction(sessionId id: UUID) {
        let alreadyStamped = lastInteractedSessionId == id
        // Stamped before the early return below, not after it: the skip is an
        // optimisation about whether anything VISIBLE can change, and a
        // keystroke still has to count as an act for ordering purposes even
        // when this particular one repaints nothing.
        stampInteraction(id)
        // `noteInteraction` fires on every keystroke — many times a second
        // while typing — and an unconditional `refresh()` re-reads settings,
        // snapshots panes/sessions, runs the tracker, diffs LED commands, and
        // publishes status, all synchronously on the main actor. Skip it when
        // it provably cannot change anything: the stamp was already this
        // session, and nothing is currently marked unread for a clear to
        // have any visible effect. Finish detection is unaffected by
        // skipping — a session's `isThinking` flip is itself an `Observation`
        // dependency of `refresh()`'s tracked closure, so it schedules its
        // own `refresh()` through `track()`'s `onChange` independent of this
        // call.
        //
        // The condition is `contains(id)`, not `!isEmpty`, and the difference
        // became load-bearing with `markSeq`: a clear can only ever remove
        // `lastInteractedSessionId`, which this call just set to `id`, so a
        // refresh cannot change anything unless `id` ITSELF is marked. Under
        // the old rule marks cleared within one `update` and `isEmpty` was
        // almost always true, so the skip fired; now a mark persists until
        // acknowledged, and `!isEmpty` would mean one full `refresh()` — a
        // `CGEventSource` syscall, a pane/session snapshot, an LED diff —
        // per keystroke for as long as ANY pane anywhere stayed lit.
        guard Self.shouldRefresh(alreadyStamped: alreadyStamped,
                                 idIsUnread: store.unreadSessionIds.contains(id))
        else { return }
        refresh()
    }

    private func focusPane(_ index: Int) {
        guard store.panes.indices.contains(index) else { return }
        // Covers the same-pane repress `refresh()`'s focus-change tracking
        // cannot see (no session change to notice) — see `noteInteraction`'s
        // doc. For the ordinary cross-pane press this duplicates what
        // `setFocusedPaneIndex` below will trigger anyway; the duplication is
        // harmless (idempotent) and buys an immediate `refresh()` instead of
        // waiting one Observation hop for the LED to catch up.
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
