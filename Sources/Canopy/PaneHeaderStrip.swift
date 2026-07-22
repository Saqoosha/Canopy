import SwiftUI

/// Title-bar-style header at the top of a pane: bold session title with
/// the project as a smaller gray subtitle beneath — the same two-line
/// look the window's unified title bar had before `.hiddenTitleBar`.
/// The window's navigationTitle can only hold one string; with N panes
/// visible we need per-pane title display. Also carries the pane's
/// close X (hover-only, hidden when showCloseButton is false — i.e.
/// when panes.count == 1).
///
/// Takes plain strings rather than an OpenSession so it can also render
/// a launcher pane (title "New Session", empty project).
struct PaneHeaderStrip: View {
    let title: String
    let project: String
    let showCloseButton: Bool
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
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
        .onHover { hovered = $0 }
    }
}
