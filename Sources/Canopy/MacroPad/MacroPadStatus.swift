import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MacroPad")

/// One-way mirror of the MacroPad's link state, for the UI to read.
///
/// `MacroPadController` owns the truth — `isConnected`, and the key count that
/// arrives off the wire in `HELLO` — but it is held by `AppDelegate`, is not
/// observable, and has no business knowing a view exists. This carries the
/// only part of its state a person can act on: whether the thing under their
/// hand is actually talking to Canopy.
///
/// Deliberately narrower than the controller's state. The protocol version and
/// the diff cache stay inside — not because nothing could be done about them
/// (a sub-v2 pad means `asking` will not pulse, and reflashing is a real
/// remedy), but because they are properties of the firmware rather than of the
/// link, and `adoptIdentity` already says so in the log.
@MainActor
@Observable
final class MacroPadStatus {
    static let shared = MacroPadStatus()

    enum Link: Equatable {
        /// The link is not running: the source is `.off`, `shutdown()`
        /// ran, or no controller has published yet (this is `link`'s initial
        /// value). The three collapse into one case because none of them is
        /// something the LINK can be made to do about — the remedy for all
        /// three is the same, which is what lets them share a case. The glyph
        /// is a control here like everywhere else, and its help text says
        /// "inactive" rather than naming the one cause the user chose, because
        /// two of the three are not that cause. Note the *controller* keeps
        /// running through all three — it also owns the unread bookkeeping.
        ///
        /// It draws a slashed glyph rather than nothing. It used to draw
        /// nothing, to keep a switched-off MacroPad out of the footer — but
        /// the glyph is the source selector now, and the machine most in need
        /// of the switch is precisely the one sitting here: the one serving
        /// its own pad to another Canopy over the bridge, which must be `.off`
        /// for `socat` to hold the port. A control that vanishes in the state
        /// it reports cannot be used to leave it.
        case disabled
        /// Enabled, and nothing has answered a probe. Unplugged, mid-probe and
        /// mid-retry collapse here because the device layer emits no `Output`
        /// that separates them.
        ///
        /// One cause that is *not* the same to the user hides in here too: a
        /// pad that is plugged in and powered but whose port is held by
        /// something else — a `screen` session or a CircuitPython IDE, which
        /// `MacroPadDevice` names as the single most common bring-up state. It
        /// logs the failed open and returns without emitting, so this case
        /// cannot tell it from an empty desk. The remedy differs and the
        /// indicator cannot say so; that is a known gap, not a simplification.
        case searching
        /// A port answered a probe. See `Keys` for what the payload can mean.
        case connected(Keys)
    }

    /// What the device has said about its key count, as three states rather
    /// than an `Int?` with a loaded zero. `MacroPadController.publishStatus`
    /// builds these from device state; `demoCycle` below builds them literally.
    ///
    /// What the enum buys is exhaustiveness at the *render* site. As an `Int?`
    /// the fault was an ordinary `if keys == 0` inside the `connected` branch,
    /// which could fall through to "connected and fine" with nothing to
    /// complain; `MacroPadIndicator.appearance(for:)` now switches over every
    /// case, so losing `unreachable` there is a compile error. The payload
    /// itself is no more bounded than the `Int?` was.
    enum Keys: Equatable {
        /// Connected, but no count has been adopted. Usually momentary — the
        /// device is adopted only *after* a `HELLO`/`PONG` is already pending,
        /// so the window is one main-queue turn and normally never reaches the
        /// screen. It persists for firmware whose `HELLO` carries no count, in
        /// which case the controller runs on `assumedKeyCount`.
        case counting
        /// The board is running but the NeoKey is not answering — an unplugged
        /// Qwiic cable makes `board.STEMMA_I2C()` throw and the firmware
        /// reports `HELLO <ver> 0` rather than dying. The one connected state
        /// worth colouring: no LED can report it, because there are no LEDs.
        /// (Firmware behaviour — the Canopy-MacroPad repo is primary for it.)
        case unreachable
        /// A real count off the wire.
        case available(Int)
    }

    private(set) var link: Link = .disabled

    /// The controller's way in — and the only writer outside this file. The
    /// demo below assigns `link` directly, which is why this is not called the
    /// sole writer.
    ///
    /// The inequality guard exists because `@Observable` notifies on every
    /// assignment, equal or not, and the controller republishes from
    /// `refresh()`, which runs on every observed change — a pane-divider drag
    /// included. Without it `MacroPadIndicator` re-renders through a whole
    /// drag. Like the `store.unreadSessionIds` guard it mirrors, it does not
    /// prevent an observation loop; it only stops the redundant renders.
    ///
    /// Its *read* also arms `link` in whatever tracked pass is running. A
    /// write made inside that same pass is free — measured: the Observation
    /// runtime installs its observers only after `apply()` returns, so it
    /// cannot wake the pass that armed it. That is observed behaviour, not a
    /// documented guarantee. A publish from outside a tracked pass does wake
    /// one extra `refresh()`, bounded because the repeat writes nothing.
    func publish(_ link: Link) {
        // Real hardware must not be able to fight the demo. Otherwise a pad
        // plugged in mid-cycle republishes on its own schedule and the states
        // being inspected flicker past at random.
        //
        // The order is load-bearing: returning here before `self.link` is read
        // keeps `link` out of the controller's tracked set while the demo
        // runs. Swapped, the demo timer's writes — which do come from outside
        // the tracked pass — would wake a full `refresh()` every tick.
        guard !isDemo else { return }
        guard self.link != link else { return }
        self.link = link
    }

    // MARK: - Demo

    /// `env CANOPY_MACROPAD_STATUS_DEMO=1 <Canopy binary>` walks the indicator
    /// through every state it can be in, one per `demoInterval`, forever.
    ///
    /// It exists because the interesting states are the ones you cannot summon
    /// on demand: `Keys.unreachable` needs a physically unplugged Qwiic cable,
    /// and `Keys.counting` is normally one main-queue turn wide. Checking a
    /// glyph's colour by arranging hardware failures is not a check anyone
    /// will repeat.
    ///
    /// Not `#if DEBUG`, unlike `CANOPY_RUN_LOGIC_PROBE`, so the shipped build
    /// can be checked too — the same reasoning as `CANOPY_RECAP_DELAY_SECONDS`.
    /// The cost is that a Release binary launched with the variable set shows
    /// a fiction until it is relaunched.
    static let demoEnvironmentKey = "CANOPY_MACROPAD_STATUS_DEMO"

    /// The states the demo walks, in cycle order — every case of `Link`, with
    /// three representatives standing in for the unbounded `connected`.
    /// `.disabled` is in the list on purpose: that tick is where you see the
    /// slashed glyph, and confirm it holds its slot rather than collapsing the
    /// row. It used to be where you confirmed the
    /// case drew nothing at all.
    ///
    /// No two *adjacent* entries are equal, so every tick visibly changes the
    /// indicator; an equal pair would read as a stalled demo. (The timer
    /// assigns `link` directly, so an equal write would still notify — the
    /// property wanted here is visual, not an `@Observable` concern.)
    static let demoCycle: [Link] = [
        .disabled,
        .searching,
        .connected(.counting),
        .connected(.available(4)),
        .connected(.unreachable),
    ]

    private static let demoInterval: TimeInterval = 1

    /// Read by the indicator, which puts the state's name on screen while the
    /// demo runs — a glyph cycling silently through `demoCycle` is not
    /// something anyone can name by looking at it.
    let isDemo: Bool
    /// Holds the timer for the object's lifetime. Never invalidated: `shared`
    /// never deallocates, and the demo has no off switch short of relaunching.
    private var demoTimer: Timer?
    private var demoIndex = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isDemo = environment[Self.demoEnvironmentKey] == "1"
        guard isDemo else { return }
        startDemo()
    }

    private func startDemo() {
        logger.notice("""
            MacroPad indicator demo: cycling \(Self.demoCycle.count, privacy: .public) states every \
            \(Int(Self.demoInterval), privacy: .public)s — real device status is suppressed
            """)
        link = Self.demoCycle[demoIndex]
        // `[weak self]` on the OUTER block, and `.common` mode: the same two
        // mechanics as `MacroPadController.startWatchdog` — a weak capture on
        // the inner `Task` alone still makes the timer's own closure capture
        // `self` strongly, and the default runloop mode stops ticking during
        // menu tracking and live resize, which is exactly when someone is
        // poking at the sidebar. Only the second mechanic has a payoff here:
        // `shared` is immortal, so there is no lifetime for the weak capture
        // to save. It is kept so the two timers read alike.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.demoInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.demoIndex = (self.demoIndex + 1) % Self.demoCycle.count
                // Assigned directly rather than through `publish`, which the
                // demo gate closes.
                self.link = Self.demoCycle[self.demoIndex]
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }
}

/// The MacroPad source selector at the start of the sidebar's version
/// footer, drawn as a link-state glyph.
///
/// It always draws, and clicking it opens the source selector — the thing
/// that reports the state is the thing that changes it. `Settings` and the
/// menu bar both switch source too; neither is where the eye already is when
/// the question "which pad am I driving?" comes up.
///
/// Every state draws, including `.disabled`. The `appearance(for:)` return
/// type is what makes a nil branch a compile error; it does not stop `body`
/// from putting a condition around the `Menu`, so "always draws" is a property
/// of both together. It is also why the indicator never vanishes when no pad
/// answers: an indicator that disappeared then could not distinguish
/// "unplugged" from "the subsystem is broken", which is the question it was
/// added to answer.
struct MacroPadIndicator: View {
    /// Defaulted rather than hardcoded so a caller could drive an injected
    /// instance. Nothing does today: the demo mode covers the same ground, and
    /// the logic probe exits before SwiftUI renders anything.
    var status: MacroPadStatus = .shared

    /// Internal rather than `private` so `_SidebarLogicProbe` can resolve
    /// every state's symbol — the one defect here that compiles, runs, and is
    /// invisible until someone looks at the window.
    struct Appearance {
        let symbol: String
        let tint: AnyShapeStyle
        let help: String
        /// State name, rendered beside the glyph only while the demo runs.
        let demoLabel: String
    }

    var body: some View {
        let appearance = Self.appearance(for: status.link)
        // `MacroPadCommands` is mounted verbatim rather than re-implemented:
        // the three rows are a radio group with one non-obvious detail (a
        // `Toggle` rather than a `Label`, so AppKit reserves the checkmark
        // column for every row) argued at length in that file. Two mount
        // points, one definition.
        Menu {
            MacroPadCommands()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appearance.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(appearance.tint)
                if status.isDemo {
                    Text(appearance.demoLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // `.borderlessButton` renders as an `NSPopUpButton`, which keeps its
        // own minimum metrics. A `.frame` does shrink it — see the measurement
        // below — but only to a floor those metrics set, so sizing the box
        // alone left the footer heavier than the released build. This is the
        // lever that moves the floor: framed at `.regular` the popup measures
        // 17pt tall, framed at `.mini` 14.
        .controlSize(.mini)
        // Measured in an `NSHostingView` harness reproducing this exact
        // modifier stack, because an earlier version of this comment argued
        // three things that turned out to be false:
        //
        //   - the frame does NOT merely centre an unshrinkable control. It
        //     shrinks it: the same `.mini` popup is 22pt wide unframed and
        //     14pt framed.
        //   - the control is not the box. The box lands at x=12 w=9; the
        //     drawn `SwiftUIPopupButton` lands at x=7 w=14 — right-aligned to
        //     the box and overhanging 5pt to its left, which moves the glyph
        //     2pt left of where the released build drew it (10 vs 12).
        //   - the height is honoured by the popup's metrics, not by the box:
        //     the layout box reports 14 tall despite `height: 9`.
        //
        // What the frame is actually for, then, is the popup's own metrics —
        // footer height is 16 unframed and 15 framed. It is load-bearing, for
        // a different reason than it was first given.
        //
        // Width is released under the demo, and only there: the demo draws
        // the state's name beside the glyph, and a fixed width clipped it —
        // caught by capturing the demo and finding the labels gone. The cost
        // is that the demo now renders a geometry users never see (120pt wide
        // against the shipped 14), so "I checked it in the demo" no longer
        // covers the shipped width.
        .frame(width: status.isDemo ? nil : Self.glyphSide, height: Self.glyphSide)
        // Kept, but it does nothing measurable: the drawn `NSPopUpButton` is
        // 14pt wide against this rect and overhangs it 5pt to the left
        // (measured in the shipped config, where the frame's width is 9; under
        // the demo it is nil. The vertical relationship was not measured, and
        // the horizontal result was right-alignment rather than centring, so
        // do not assume symmetry). AppKit does its own hit testing, so the
        // real target is the 14×14 control. Left in as the SwiftUI-side
        // statement of intent rather than removed on a measurement that only
        // covers geometry.
        .contentShape(Rectangle())
        // `.ignore` before the label, so the glyph and the demo's state name
        // cannot each inherit it and announce twice. They sit inside the
        // `Menu`'s label now rather than being direct children of the modified
        // view, and whether flattening a `Menu` this way costs VoiceOver the
        // popup's own role and show-menu action is NOT measured — it needs a
        // real window, which neither the probe nor a headless harness has.
        .accessibilityElement(children: .ignore)
        .help(appearance.help)
        .accessibilityLabel(appearance.help)
    }

    /// The box the `Menu` is given. It governs the popup's metrics, and the
    /// footer's size through them: measured 16pt tall unframed, 15pt framed.
    ///
    /// It does NOT normalise anything about the symbols, and two earlier
    /// versions of this doc claimed it did — first that their differing
    /// bounds moved the row's HEIGHT, then, as the correction, that they
    /// moved its WIDTH. Both are false and the second is worse, because the
    /// figures it cited refute it in the same sentence: `square.slash` is
    /// 11x13 and `square.grid.2x2` is 11x11, so they differ in height and
    /// share a width. Measured across all three symbols and all four
    /// framed/unframed combinations, the footer comes out identical per
    /// symbol — the popup's own minimum metrics absorb the variation
    /// entirely, so symbol bounds move neither axis. There was also nothing
    /// to normalise before this PR: only two symbols existed and both were
    /// 11x11.
    ///
    /// The inner `.frame` those claims justified is gone with them. What is
    /// left is this one, on the `Menu`.
    ///
    /// Do not cite this file's older note about "watching the version text
    /// slide left and back" here, as both of those versions did. Read in
    /// full, it is about `.disabled` returning nil and the glyph VANISHING —
    /// the row reflowing around an absent indicator, not around a differently
    /// sized one. The citation inverts its source.
    ///
    /// 9, matching the symbol's own point size, so the box is the type size
    /// rather than a number picked to look about right. The first version of
    /// this used 11 and read visibly larger than the released build — the
    /// glyph itself never changed size (a `.frame` sets the layout box, it
    /// does not scale the image), so what grew was the space around it.
    private static let glyphSide: CGFloat = 9

    /// Every state's `help` names the click, not just the one that reads as
    /// broken: the glyph is the same control in all of them, and a tooltip
    /// that mentions the affordance in one state only teaches that clicking
    /// is for fixing something.
    ///
    /// Total, and that is the load-bearing part: the glyph is now the source
    /// selector, and a control that draws nothing cannot be clicked to leave
    /// the state it is reporting. `.disabled` used to return nil so a
    /// switched-off MacroPad did not occupy the footer — which meant the one
    /// machine most in need of the switch, the one currently serving its pad
    /// to another Canopy over the bridge, had nothing to click.
    ///
    /// The old branch also paid for something that no longer applies: keeping
    /// the footer free for someone who has no pad and never will. This app
    /// has one user and he has two of them.
    ///
    /// The return type is the invariant. Re-introducing a nil branch is a
    /// compile error rather than a silently unreachable control.
    static func appearance(for link: MacroPadStatus.Link) -> Appearance {
        switch link {
        case .disabled:
            // Slashed, not absent: this is a state the user can leave, so it
            // reads as switched-off hardware rather than as missing hardware.
            // Quaternary keeps it from competing with the version string it
            // sits beside.
            //
            // "inactive", not "off": this case collapses three causes and only
            // one of them is the user's choice. The initial value is also here
            // — `MacroPadController.start()` runs from a `.task`, so it lands
            // AFTER the first render — and claiming "off" in that window would
            // tell a `.local` machine its pad is switched off. Drawing nothing
            // made no claim at all, which is what this case used to do.
            //
            // `square.slash`, not `square.grid.2x2.slash` — the latter is not
            // a real SF Symbol and renders as a broken-image glyph. Caught by
            // eye; the probe now resolves every symbol reachable through
            // `MacroPadStatus.demoCycle`, which today covers all five states,
            // so the next typo fails a test instead. See the probe for what
            // that does and does not buy.
            return Appearance(symbol: "square.slash",
                              tint: AnyShapeStyle(.quaternary),
                              help: "MacroPad inactive — click to change source",
                              demoLabel: "off")
        case .searching:
            // Outline + quaternary: findable when you go looking for it,
            // quiet enough not to read as a warning. An unplugged pad is the
            // normal state for most of the day.
            return Appearance(symbol: "square.grid.2x2",
                              tint: AnyShapeStyle(.quaternary),
                              help: "MacroPad not connected — click to change source",
                              demoLabel: "searching")
        case .connected(.unreachable):
            return Appearance(symbol: "square.grid.2x2",
                              tint: AnyShapeStyle(Color.orange.opacity(0.8)),
                              help: "MacroPad connected, but the NeoKey is not responding — check the Qwiic cable. Click to change source",
                              demoLabel: "connected · 0 keys")
        case .connected(.counting):
            return Appearance(symbol: "square.grid.2x2.fill",
                              tint: AnyShapeStyle(.tertiary),
                              help: "MacroPad connected — click to change source",
                              demoLabel: "connected · no count")
        case .connected(.available(let count)):
            return Appearance(symbol: "square.grid.2x2.fill",
                              tint: AnyShapeStyle(.tertiary),
                              help: "MacroPad connected — \(count) \(count == 1 ? "key" : "keys"). Click to change source",
                              demoLabel: "connected · \(count) keys")
        }
    }
}
