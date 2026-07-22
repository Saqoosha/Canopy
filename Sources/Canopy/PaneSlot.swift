import Foundation

/// What a pane is currently showing.
enum PaneContent: Equatable {
    /// Session view for the given OpenSession.
    case session(OpenSession.ID)
    /// Launcher view (new-session flow). Reached via Cmd+N or Cmd+click
    /// the Launcher row in the sidebar.
    case launcher
}

/// One horizontal pane in the detail column. Points at either an
/// OpenSession (identity of the shim + webview living in
/// SessionStore.openSessions) or the launcher, and remembers the pane's
/// currently-preferred width. Layout in Detail.swift reads preferredWidth;
/// divider drag mutates it.
struct PaneSlot: Equatable, Identifiable {
    let id: UUID
    var content: PaneContent
    var preferredWidth: CGFloat

    init(id: UUID = UUID(), content: PaneContent, preferredWidth: CGFloat) {
        self.id = id
        self.content = content
        self.preferredWidth = max(1, preferredWidth)
    }
}
