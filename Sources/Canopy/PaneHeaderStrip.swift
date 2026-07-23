import SwiftUI

/// Title-bar-style header at the top of a pane: 13pt semibold session
/// title with the project as a smaller gray subtitle beneath — the same
/// two-line look the window's unified title bar had before
/// `.hiddenTitleBar`.
/// The window's navigationTitle can only hold one string; with N panes
/// visible we need per-pane title display. Also carries the pane's
/// close X (hover-only, hidden when showCloseButton is false — i.e.
/// when panes.count == 1).
///
/// Takes plain strings rather than an OpenSession so it can also render
/// a launcher pane (title "New Session", empty project).
struct PaneHeaderStrip: View {
    /// Fixed leading padding every pane header uses. Kept as a shared constant
    /// so `PaneHeaderChromeAvoidanceProbe` (in `Detail.swift`) can subtract the
    /// same value when computing how much extra inset the leftmost pane needs
    /// to clear the traffic-light cluster.
    static let baseLeadingPadding: CGFloat = 12

    let title: String
    let project: String
    let showCloseButton: Bool
    /// Extra leading inset the *leftmost* pane header takes so its title stays
    /// clear of the traffic-light cluster + collapsed-sidebar toggle. Panes at
    /// index > 0 MUST pass 0 (the default) — a non-zero value on a non-leftmost
    /// pane visibly misaligns the header title.
    var leadingChromeAvoidance: CGFloat = 0
    let onClose: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !project.isEmpty {
                    Text(project)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if showCloseButton && hovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close pane (⌘W)")
            }
        }
        .padding(.leading, Self.baseLeadingPadding + leadingChromeAvoidance)
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
        .onHover { hovered = $0 }
    }
}
