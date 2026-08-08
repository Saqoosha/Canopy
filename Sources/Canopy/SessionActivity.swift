import SwiftUI

/// The one activity classification shared by the sidebar row dot and the
/// MacroPad LED. Both renderers derive from this enum, so a state can never
/// mean one thing on screen and another under the user's hand — the whole
/// point of the pad is that a glance at the sidebar and a glance at the keys
/// tell the same story.
///
/// Deliberately NOT modelled as "one case per flag on `OpenSession`": the
/// flags overlap — a crashed session can still have `isThinking` set, and an
/// asking one usually does — so the classification is a priority ladder, not
/// a product. `of(_:isUnread:)` owns that ladder and is the only place allowed
/// to know the order.
enum SessionActivity: Equatable, Sendable, CaseIterable {
    /// No session at this position — an empty pane slot or a launcher pane.
    /// Only reachable on the pad; every sidebar open row has a session.
    case empty
    /// Alive, nothing in flight, nothing owed to the user.
    case idle
    /// Claude is generating (`isThinking`), or the shim is still coming up
    /// (`status == .spawning`). Deliberately one state: spawning is a few
    /// hundred ms of "the machine is busy, not your turn", which is exactly
    /// what thinking means. Splitting them would need a second blue, and a
    /// second blue is a brightness distinction — see `ledColor`.
    case working
    /// Claude itself is idle but a `run_in_background` Bash/Agent is still
    /// running (`isWaiting`). Alive, but not the user's turn either.
    case background
    /// A tool-permission request or `AskUserQuestion` is outstanding
    /// (`isAsking`). The user MUST act — the only blinking state.
    case asking
    /// Finished while the user was looking at a different pane. Cleared the
    /// moment that pane takes focus. See `MacroPadController` for the edge
    /// detection; this enum only names the state.
    case unread
    /// Shim crashed, or an SSH session gave up reconnecting.
    case error

    /// Priority ladder, highest first. `asking` beats `working` because a
    /// permission prompt has already paused Claude — the row is waiting on the
    /// human, not on the model. Both the sidebar and the pad render from this,
    /// so this order *is* the precedence; there is no second one to match.
    static func of(_ session: OpenSession, isUnread: Bool) -> SessionActivity {
        if case .crashed = session.status { return .error }
        if session.connection.status == .reconnectFailed { return .error }
        if session.isAsking { return .asking }
        if session.isThinking || session.status == .spawning { return .working }
        if session.isWaiting { return .background }
        if isUnread { return .unread }
        return .idle
    }

    /// A sine breathe between `floorPercent` and full, over `periodMs`.
    /// Replaced a 1 Hz square blink after the square wave was seen on real
    /// hardware and judged too harsh.
    struct Breath: Equatable, Sendable {
        let periodMs: Int
        /// Trough as a percentage of the state's color. The smaller it is, the
        /// deeper the breath and the more the key demands attention.
        let floorPercent: Int
    }

    /// Nothing / "alive" / "answer me", encoded as amplitude.
    ///
    /// The original rule was "exactly one state animates" — two competing
    /// blinks cancel out in peripheral vision, which is the only vision the
    /// pad gets when it's doing its job. Three states animate now, and the
    /// rule survives in a stronger form because the amplitudes are a ladder,
    /// not a set: a floor of 50 barely moves and reads as static from the
    /// corner of the eye, while a floor of 10 swings nearly the whole range.
    /// The floors were picked by watching a real pad from peripheral vision
    /// and checking that only orange still called out — measured, not
    /// reasoned. `breathIsOrdered` is the invariant that keeps it that way.
    ///
    /// This is a second axis, deliberately orthogonal to hue: amplitude
    /// encodes urgency, hue encodes state. Amplitude is never the *sole*
    /// carrier of identity — every pair of states differs in hue as well — so
    /// the "hue only" rule in `ledColor` still holds.
    var breath: Breath? {
        switch self {
        case .working: return Breath(periodMs: 2000, floorPercent: 50)
        case .background: return Breath(periodMs: 2000, floorPercent: 40)
        case .asking: return Breath(periodMs: 2000, floorPercent: 10)
        case .empty, .idle, .unread, .error: return nil
        }
    }

    /// The whole design in one predicate: whatever the floors are tuned to,
    /// `asking` must breathe strictly deeper than anything else. The moment a
    /// second state matches or beats it, the pad stops being able to say
    /// "this one needs a human" and becomes decoration.
    static var breathIsOrdered: Bool {
        guard let asking = SessionActivity.asking.breath else { return false }
        return allCases
            .filter { $0 != .asking }
            .compactMap(\.breath)
            .allSatisfy { $0.floorPercent > asking.floorPercent }
    }

    // MARK: - LED rendering

    /// 24-bit RGB sent to the pad as `C <idx> <rrggbb>`.
    ///
    /// Two rules the values encode, both learned the expensive way:
    ///
    /// **States are distinguished by hue only, never by brightness.** Ambient
    /// light swamps a brightness difference, so a "dim blue" and a "bright
    /// blue" read as the same key. Every value below differs from every other
    /// in hue.
    ///
    /// **Send full-scale colors and let the global `B` command do the
    /// dimming.** `pixels.brightness` on the NeoPixel is a plain multiply
    /// against the 8-bit channel, so a pre-dimmed color dims twice. `idle` was
    /// originally `0x101010`, which at 30% brightness lands on (4, 4, 4) —
    /// inside the range where WS2812/SK6812 channels quantise coarsely and
    /// drift in hue per unit. Lifting it clear of that floor is why it starts
    /// at `0x27`/`0x30` rather than `0x10`.
    ///
    /// **`idle` is white-balanced, not neutral.** Equal RGB does not look grey
    /// through a clear keycap — the green channel is the weak one, so
    /// `0x303030` reads visibly purple. The correction is measured, and the
    /// surprise is that it is *output-level dependent*: at the same brightness
    /// setting, full white needs about 6% off red and blue while this dark
    /// grey needs about 18%. Channel efficiency diverges as drive current
    /// falls, so no single global white balance can be right at both ends. Any
    /// future colour on the grey axis needs its own measurement; the six
    /// saturated colours are unaffected because they lean on one channel.
    ///
    /// **`background` and `unread` cannot be tuned independently of each
    /// other or of `working`.** They sit next to each other on the hue circle
    /// — blue, cyan, green — so moving the middle one away from blue moves it
    /// toward green by exactly as much. A plain cyan (`0x00C0C0`) read as too
    /// close to blue on real hardware; `0x00FFA0` moves both of its channels
    /// (green `C0`→`FF`, blue `C0`→`A0`) to open a wide gap against blue, and
    /// `unread` then had to move from `0x00FF40` to pure green to get back out
    /// of *its* way. Changing any one of these three is a three-way retune, on
    /// hardware, not an edit here.
    var ledColor: UInt32 {
        switch self {
        case .empty: return 0x00_00_00
        case .idle: return 0x27_30_27
        case .working: return 0x00_40_FF
        case .background: return 0x00_FF_A0
        case .asking: return 0xFF_80_00
        case .unread: return 0x00_FF_00
        case .error: return 0xFF_00_00
        }
    }

    // MARK: - Sidebar rendering

    /// Screen counterpart of `ledColor`. Same hues, different values: the LED
    /// values assume a black background and a diffusing keycap, while these
    /// sit on the sidebar's light background and have to stay legible at 7pt.
    /// Keep the hue families in step — that correspondence is the feature.
    ///
    /// Components rather than a `Color` because state changes cross-fade, and
    /// `Color` has no blend. `.empty` is never rendered by the sidebar (every
    /// open row has a session) but still carries real components instead of
    /// `.clear`, so nothing has to special-case an alpha-zero endpoint mid
    /// fade — the pad expresses "empty" through `ledColor`'s black.
    var dotRGB: RGBComponents {
        switch self {
        case .empty, .idle: return RGBComponents(red: 0.62, green: 0.62, blue: 0.62)
        case .working: return RGBComponents(red: 0.16, green: 0.42, blue: 0.95)
        case .background: return RGBComponents(red: 0.00, green: 0.68, blue: 0.55)
        case .asking: return RGBComponents(red: 0.98, green: 0.52, blue: 0.11)
        case .unread: return RGBComponents(red: 0.20, green: 0.66, blue: 0.13)
        case .error: return RGBComponents(red: 0.88, green: 0.24, blue: 0.22)
        }
    }

    var dotColor: Color { dotRGB.color }

    /// How long a state change takes to cross-fade on screen. An abrupt colour
    /// change reads as "something just happened", which overstates most
    /// transitions — working → background is a state easing from one to the
    /// next, not an event.
    ///
    /// The pad fades over the same 500 ms, but that is the **firmware's own
    /// default** (protocol v3 exposes an `X <ms>` command; Canopy never sends
    /// one, and `MacroPadCommand` has no case for it). So the two sides match
    /// by agreement, not by construction: changing this constant desyncs them,
    /// and so does a firmware retune, with nothing on either side to notice.
    static let crossfade: TimeInterval = 0.5

    /// Idle is the quiet baseline and stays the small 6pt dot the sidebar has
    /// always drawn; everything that is reporting something gets a slightly
    /// larger one.
    ///
    /// Note what this does **not** do: it separates idle from the rest, and
    /// nothing else. The five reporting states are told apart by hue alone
    /// (breath separates three of them), where the icons this replaced used a
    /// distinct SF Symbol per state — so colour is load-bearing here in a way
    /// it was not before, and a red-green deficiency would collapse the
    /// working/background/unread trio.
    ///
    /// That is a decided trade, not an oversight: this app has one user, who
    /// asked for a plain coloured dot knowing what it costs. Recorded so the
    /// question doesn't get re-opened by every review — the answer is not
    /// "nobody noticed", it is "noticed and accepted".
    var dotDiameter: CGFloat { self == .idle ? 6 : 8 }

    /// VoiceOver / tooltip label. Also what the pad's states are called in
    /// logs, so a bug report reads the same as the UI.
    var label: String {
        switch self {
        case .empty: return "Empty"
        case .idle: return "Idle"
        case .working: return "Working"
        case .background: return "Background task running"
        case .asking: return "Waiting for you"
        case .unread: return "Finished"
        case .error: return "Error"
        }
    }
}

/// A colour that can be blended. SwiftUI's `Color` is opaque and offers no
/// interpolation, and animating it implicitly is not an option here because
/// the dot's opacity is recomputed every frame from the breath curve — an
/// implicit animation would be fighting a per-frame assignment.
struct RGBComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static func lerp(_ from: RGBComponents, _ to: RGBComponents, _ t: Double) -> RGBComponents {
        RGBComponents(
            red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t
        )
    }
}

/// The same sine the firmware runs — `(1 - cos(2πφ)) / 2`, blended from the
/// floor — so a breathing sidebar dot and a breathing key follow the same
/// curve at the same period and depth. The firmware applies a gamma to that
/// level which is currently 1.0; if it is ever retuned, the two sides drift
/// apart with nothing here to notice.
enum BreathPhase {
    /// Trough at the moment the row *entered* a breathing state, rising to
    /// full a half period later. `since` is that moment.
    ///
    /// Anchoring to that transition rather than to the wall clock is what
    /// de-phases the rows: sessions start breathing at different times, so
    /// their breaths are naturally spread with nothing to coordinate. When
    /// every row troughs together the asking row's peak lands in everyone
    /// else's darkness and stops standing out. The pad's keys spread for the
    /// same reason and by the same mechanism — the firmware has no phase
    /// offset of its own — but the two spreads are independent: a reconnect
    /// re-anchors every key on the device while the dots keep their anchors,
    /// so the correspondence is one of behaviour, not of phase.
    ///
    /// **Entered**, not "changed": a move from one breathing state to another
    /// keeps the anchor, so the breath carries on uninterrupted while the
    /// colour and floor cross-fade underneath it. Restarting it there would
    /// make the pulse visibly stumble, and a stumble is louder than the change
    /// it was reporting — the user's read is that urgency changed, not that
    /// the heartbeat stopped.
    ///
    /// It is also the firmware's definition of phase zero (the instant an `S`
    /// lands for a key that was not already breathing), and Canopy sends that
    /// `S` from the same transition — so a dot and its key start together, and
    /// stay together until something re-anchors one side alone. A reconnect
    /// does exactly that, and nothing tries to re-sync them afterwards.
    static func level(at date: Date, since start: Date, breath: SessionActivity.Breath) -> Double {
        let floor = Double(breath.floorPercent) / 100
        let period = Double(breath.periodMs) / 1000
        let phase = (date.timeIntervalSince(start) / period).truncatingRemainder(dividingBy: 1)
        let rise = 0.5 - 0.5 * cos(2 * .pi * phase)
        return floor + (1 - floor) * rise
    }
}

/// A dot that breathes on the same curve, period and floor as the MacroPad's
/// key. Static states render as a plain dot with no timeline overhead.
///
/// The breath is anchored when a row *enters* a breathing state and carries
/// across breathing → breathing untouched, so only colour and floor move; see
/// `BreathPhase.level(at:since:breath:)` for why that matters and why it also
/// keeps rows out of phase with each other.
/// A row rebuilt from scratch (a List recycling its views) restarts its breath
/// rather than continuing one; that is a cosmetic reset of a 2 s animation, and
/// paying for a store-side transition timestamp to avoid it would be worse.
struct ActivityDot: View {
    let activity: SessionActivity

    /// Where the current breath started. Preserved across breathing →
    /// breathing so only colour and floor move.
    @State private var breathStart = Date()
    /// The state being faded out of, and when the fade began. `nil` once the
    /// fade has finished, which is also what drops the per-frame timeline for
    /// rows that are not breathing.
    @State private var fadingFrom: SessionActivity?
    @State private var fadeStart = Date()
    @State private var fadeEnd: Task<Void, Never>?

    var body: some View {
        // The observer sits outside the branch on purpose: attaching it to the
        // breathing case only would mean the static → breathing transition —
        // the one that starts a breath — happens before the modifier exists,
        // leaving the new breath anchored to whenever the row first appeared.
        content
            .onChange(of: activity) { old, new in
                // Entering a breath from rest re-anchors it; carrying on from
                // another breath does not. See `BreathPhase.level`.
                if old.breath == nil, new.breath != nil { breathStart = Date() }
                fadingFrom = old
                fadeStart = Date()
                fadeEnd?.cancel()
                fadeEnd = Task {
                    try? await Task.sleep(for: .seconds(SessionActivity.crossfade))
                    guard !Task.isCancelled else { return }
                    fadingFrom = nil
                }
            }
            .onDisappear {
                fadeEnd?.cancel()
                fadeEnd = nil
                // Also clear the fade: `content` keeps the row on a per-frame
                // timeline while this is set, so a row that disappears
                // mid-fade would come back animating forever.
                fadingFrom = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        if activity.breath != nil || fadingFrom != nil {
            // 30 fps, not the display's refresh rate: a 2 s sine and a 0.5 s
            // fade are indistinguishable at 120 Hz, and the animated icons
            // this replaced deliberately throttled too.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                dot(at: context.date)
            }
        } else {
            // A settled, non-breathing dot has nothing to redraw. Keeping it
            // off the timeline means an idle sidebar costs no frames.
            dot(at: fadeStart)
        }
    }

    private func dot(at date: Date) -> some View {
        let progress = fadeProgress(at: date)
        let from = fadingFrom ?? activity
        let rgb = RGBComponents.lerp(from.dotRGB, activity.dotRGB, progress)
        let diameter = from.dotDiameter + (activity.dotDiameter - from.dotDiameter) * progress
        let opacity = level(of: from, at: date) + (level(of: activity, at: date) - level(of: from, at: date)) * progress

        return Circle()
            .fill(rgb.color)
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
            .help(activity.label)
            .accessibilityLabel(activity.label)
    }

    /// Eased so the fade starts and ends softly; a linear cross-fade still
    /// reads as a switch at both ends.
    private func fadeProgress(at date: Date) -> Double {
        guard fadingFrom != nil else { return 1 }
        let elapsed = date.timeIntervalSince(fadeStart) / SessionActivity.crossfade
        let t = min(1, max(0, elapsed))
        return t * t * (3 - 2 * t)
    }

    /// Both endpoints of the fade are sampled against the *same* breath
    /// anchor, so a floor change (working's 50 → asking's 10) interpolates as
    /// a widening of the same pulse rather than as a jump.
    private func level(of state: SessionActivity, at date: Date) -> Double {
        guard let breath = state.breath else { return 1 }
        return BreathPhase.level(at: date, since: breathStart, breath: breath)
    }
}
