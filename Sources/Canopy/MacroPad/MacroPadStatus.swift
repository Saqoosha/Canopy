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
        /// The link is not running: the Settings toggle is off, `shutdown()`
        /// ran, or no controller has published yet (this is `link`'s initial
        /// value). The three collapse into one case because none of them is
        /// something the user can act on. Note the *controller* keeps running
        /// through all three — it also owns the unread bookkeeping.
        ///
        /// Note what this case does **not** buy. `CanopySettings.macroPadSource`
        /// defaults to `.local`, so a user who has never heard of the MacroPad
        /// is in `.searching`, not here — the quiet outline glyph is the
        /// resting state for everyone without hardware, and only an explicit
        /// trip to Settings removes it. Hiding on `.disabled` alone does not
        /// make the indicator free; see `MacroPadIndicator`.
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
    /// `.disabled` is in the list on purpose even though it draws nothing —
    /// that tick is where you see whether the case is genuinely empty rather
    /// than a transparent glyph holding its slot.
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

/// Tiny link-state glyph at the start of the sidebar's version footer.
///
/// It draws nothing only in `Link.disabled`. Since `macroPadSource` defaults
/// to `.local`, that is **not** the no-hardware case: a user with no pad sits in
/// `.searching` and carries the quiet outline glyph until they turn the
/// feature off in Settings. That is the deliberate trade — an indicator that
/// vanished whenever no pad answered could not distinguish "unplugged" from
/// "the subsystem is broken", which is the question it was added to answer.
struct MacroPadIndicator: View {
    /// Defaulted rather than hardcoded so a caller could drive an injected
    /// instance. Nothing does today: the demo mode covers the same ground, and
    /// the logic probe exits before SwiftUI renders anything.
    var status: MacroPadStatus = .shared

    private struct Appearance {
        let symbol: String
        let tint: AnyShapeStyle
        let help: String
        /// State name, rendered beside the glyph only while the demo runs.
        let demoLabel: String
    }

    var body: some View {
        if let appearance = Self.appearance(for: status.link) {
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
            // `.ignore` before the label so the demo's two children cannot
            // each inherit it and announce twice.
            .accessibilityElement(children: .ignore)
            .help(appearance.help)
            .accessibilityLabel(appearance.help)
        }
    }

    /// Nil means "draw nothing at all" — the one branch that has to survive
    /// every later edit intact, since it is what keeps a switched-off MacroPad
    /// from occupying the footer.
    private static func appearance(for link: MacroPadStatus.Link) -> Appearance? {
        switch link {
        case .disabled:
            // Under the demo this tick is indistinguishable from the timer
            // having died. That is fine — the next state lands one interval
            // later, and watching the version text slide left and back is
            // precisely what confirms this case draws nothing.
            return nil
        case .searching:
            // Outline + quaternary: findable when you go looking for it,
            // quiet enough not to read as a warning. An unplugged pad is the
            // normal state for most of the day.
            return Appearance(symbol: "square.grid.2x2",
                              tint: AnyShapeStyle(.quaternary),
                              help: "MacroPad not connected",
                              demoLabel: "searching")
        case .connected(.unreachable):
            return Appearance(symbol: "square.grid.2x2",
                              tint: AnyShapeStyle(Color.orange.opacity(0.8)),
                              help: "MacroPad connected, but the NeoKey is not responding — check the Qwiic cable",
                              demoLabel: "connected · 0 keys")
        case .connected(.counting):
            return Appearance(symbol: "square.grid.2x2.fill",
                              tint: AnyShapeStyle(.tertiary),
                              help: "MacroPad connected",
                              demoLabel: "connected · no count")
        case .connected(.available(let count)):
            return Appearance(symbol: "square.grid.2x2.fill",
                              tint: AnyShapeStyle(.tertiary),
                              help: "MacroPad connected — \(count) \(count == 1 ? "key" : "keys")",
                              demoLabel: "connected · \(count) keys")
        }
    }
}
