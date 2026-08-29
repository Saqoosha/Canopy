import SwiftUI

/// Title-bar-style header at the top of a pane: 13pt semibold session
/// title with the project as a smaller gray subtitle beneath — the same
/// two-line look the window's unified title bar had before
/// `.hiddenTitleBar`.
/// The window's navigationTitle can only hold one string; with N panes
/// visible we need per-pane title display. Also carries the pane's
/// close X (hidden when showCloseButton is false — i.e. when
/// panes.count == 1).
///
/// **No mouse click is known to reach what this view draws, where
/// `Detail.swift` places it** — flush to the window top in the detail column.
/// macOS 26 layers a `BackdropView` over that band. Two things were observed,
/// and they are different in kind: the X visibly closed nothing when clicked,
/// and a hit-test probe over the X's own x range returned `BackdropView <
/// HostingScrollView < PlatformContainer < NSHostingView<…>` at y=13 and at
/// y=39, against `NSClipView` for a click deep in the pane — so the probe
/// discriminates by depth. It cannot discriminate SwiftUI's Button from its
/// host: the backdrop is itself inside that `NSHostingView`, and a hit test
/// names an NSView, never what SwiftUI would have done with the event. Only
/// two heights, and one x range, were sampled; assume the whole 48pt strip is
/// covered rather than that y=40…47 is safe. (The backdrop is presumably the
/// scroll-edge glass effect belonging to that `HostingScrollView` — the
/// ancestry is measured, the purpose inferred.)
///
/// So the close X is hit-tested by `AppDelegate`'s pane click monitor against
/// `closeButtonHitRect(paneWidth:)`, and the `Button` below only draws it.
/// Same lesson, different surface, as pane focus over a WKWebView: in this
/// window, top-of-detail-column clicks belong to an NSEvent monitor, not to
/// SwiftUI hit-testing.
///
/// Takes plain strings rather than an OpenSession so it can also render
/// a launcher pane (title "New Session", empty project).
struct PaneHeaderStrip: View {
    /// Fixed leading padding every pane header uses. Kept as a shared constant
    /// so `PaneHeaderChromeAvoidanceProbe` (in `Detail.swift`) can subtract the
    /// same value when computing how much extra inset the leftmost pane needs
    /// to clear the traffic-light cluster.
    static let baseLeadingPadding: CGFloat = 12

    /// Height of the strip. Load-bearing for `closeButtonHitRect(paneWidth:)`,
    /// which centres the X vertically in it.
    static let height: CGFloat = 48

    /// Trailing padding of the strip's content. Load-bearing for
    /// `closeButtonHitRect(paneWidth:)`, which measures the X in from the
    /// pane's trailing edge.
    static let trailingPadding: CGFloat = 12

    /// Side of the X's drawn box, vertically centred in the strip.
    private static let buttonSide: CGFloat = 16
    /// Slop around the drawn box, to give the monitor a comfortable target.
    /// Must stay at or below `(height - buttonSide) / 2` (16) to keep the rect
    /// inside the strip vertically, and below `trailingPadding` (12) to keep it
    /// inside the pane horizontally. Neither bound is enforced.
    private static let hitSlop: CGFloat = 8

    let title: String
    let project: String
    /// Peer name for this pane's session, when it is running under one. A
    /// launcher pane passes nil — it has no session, so it has no peer.
    ///
    /// This rides the title line instead of taking a line of its own, which
    /// is the opposite of what the sidebar does with the same string. Both
    /// follow from width: a pane is hundreds of points across and the chip
    /// never crowds the title, while a 280pt sidebar row cannot seat both.
    /// The strip is also sized for two lines, and a third would change the
    /// height every `closeButtonHitRect` precondition is written against.
    ///
    /// The render site gives it `layoutPriority(-1)` so it compresses before
    /// the title does. It still contributes incompressible chrome — its
    /// border and padding — to the header's `HStack`, which is the subject of
    /// that method's third precondition. The bound is unchanged in kind; it
    /// is only tighter by the width of a chip.
    var peerName: String? = nil
    let showCloseButton: Bool
    /// Extra leading inset the *leftmost* pane header takes so its title stays
    /// clear of the traffic-light cluster + collapsed-sidebar toggle. Panes at
    /// index > 0 MUST pass 0 (the default) — a non-zero value on a non-leftmost
    /// pane visibly misaligns the header title.
    var leadingChromeAvoidance: CGFloat = 0
    let onClose: () -> Void

    /// Where the close X accepts a click, in pane-local points with the origin
    /// at the pane's top-left and y growing DOWN — the coordinate space
    /// `installPaneFocusClickMonitor` already works in. See the type doc for
    /// why the button is not hit-tested by SwiftUI at all.
    ///
    /// Three preconditions, none enforced, all silent when broken:
    ///
    /// - **The pane is flush to the window top.** The monitor's y is
    ///   content-view-local; that equals pane-local only because `Detail.swift`
    ///   puts `.ignoresSafeArea(edges: .top)` on each layout child. Add a top
    ///   inset above the strip and the rect ends up ~28pt above the drawn
    ///   glyph — the X stops closing and starts focusing, with no compile
    ///   error and no log.
    /// - **The header spans exactly `paneWidth`.** `WeightedPaneLayout`
    ///   proposes `paneW` plus a trailing divider only where one is drawn, and
    ///   the pane's own `HStack` pins that divider to
    ///   `SessionStore.paneDividerWidth`; the last pane reaches the same place
    ///   by having no divider at all. Move the divider inside `paneCell` and
    ///   this rect is 8pt off.
    /// - **The header's `HStack` does not overflow.** The X is fixed-size and
    ///   everything left of it compresses down to a floor, so its trailing
    ///   edge sits at `paneWidth - trailingPadding` only while the
    ///   incompressible chrome fits. On the LEFTMOST pane with the sidebar
    ///   collapsed, `leadingChromeAvoidance` reaches ~134pt, so the header
    ///   needs ~190pt against a `paneMinDragWidth` of 100 — a narrow pane 0
    ///   pushes the drawn glyph out past this rect and past the pane, while
    ///   the rect stays where it was. Both halves of that misroute clicks: the
    ///   rect is armed over blank header space, and where it lands on the
    ///   traffic lights or on pane 1's own rect, a click meant for the zoom
    ///   button or for the neighbour's X closes a pane instead. Do not
    ///   re-derive the safe widths here — a worked example in this comment has
    ///   now been wrong twice, in each case by dropping one term. Sharing the
    ///   constants makes the two agree arithmetically; nothing makes them
    ///   agree geometrically.
    static func closeButtonHitRect(paneWidth: CGFloat) -> CGRect {
        CGRect(
            x: paneWidth - trailingPadding - buttonSide,
            y: (height - buttonSide) / 2,
            width: buttonSide,
            height: buttonSide
        )
        .insetBy(dx: -hitSlop, dy: -hitSlop)
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let peerName {
                        PeerNameChip(name: peerName)
                            .layoutPriority(-1)
                    }
                }
                if !project.isEmpty {
                    Text(project)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if showCloseButton {
                // Always drawn, never hover-gated: a launcher pane has no
                // sidebar row of its own, so with the X hidden its only
                // remaining close path was ⌘W — which acts on the focused
                // pane, and the sidebar can only show THAT a launcher pane is
                // focused (the New session button takes the accent), never
                // which one when two are open. That combination left a
                // launcher pane with no discoverable way to close it.
                //
                // No mouse click reaches `onClose`, and a future macOS
                // uncovering the strip would not change that: the click
                // monitor runs before AppKit dispatch and consumes every hit
                // inside the rect, so it wins whether or not the backdrop is
                // there. What DOES still reach this action is non-pointer
                // activation — VoiceOver's AXPress invokes it directly rather
                // than by hit-testing. So this has to stay correct, not
                // merely present.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.buttonSide, height: Self.buttonSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close pane (⌘W)")
            }
        }
        .padding(.leading, Self.baseLeadingPadding + leadingChromeAvoidance)
        .padding(.trailing, Self.trailingPadding)
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}
