import SwiftUI

/// The detail pane of the single-window shell. Renders one of:
///   - LauncherView (when selection == .launcher)
///   - SessionContainer for the selected open session
///
/// Only the active SessionContainer is mounted. WebViewContainer wraps a
/// host NSView and swaps the WKWebView subview in-place when its bound
/// OpenSession changes (~10–30 ms), so DOM state survives across switches
/// without a SwiftUI re-mount.
struct Detail: View {
    @Bindable var store: SessionStore

    @ViewBuilder
    var body: some View {
        // No ZStack: render exactly one of launcher / session. Background
        // color is provided by NavigationSplitView's detail column. With
        // a ZStack here, WKWebView's NSView could end up alongside the
        // launcher in the same NSHostingView and steal clicks on resize.
        Group {
            if case .session(let id) = store.selection,
               let session = store.openSessions.first(where: { $0.id == id }) {
                SessionContainer(session: session) { _ in
                    store.closeSession(session.id)
                }
                // No `.id(session.id)` — WebViewContainer now wraps the
                // WKWebView in a host NSView and swaps the WebView in
                // place via `updateNSView`. SwiftUI keeps the same view
                // identity, so switching is ~10ms instead of ~200ms
                // (no SwiftUI re-mount, no NSView re-parent).
            } else {
                DetailLauncher(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
    }

    /// Window title tracks the active session's title; falls back to "Canopy"
    /// when the launcher is selected. NavigationSplitView's detail column
    /// title automatically becomes the window title on macOS.
    private var windowTitle: String {
        if let active = store.activeSession, !active.title.isEmpty {
            return active.title
        }
        return "Canopy"
    }

    /// Subtitle = project name. Renders as the secondary text in the title
    /// bar (smaller, dimmed) on macOS, e.g. "My session — Canopy".
    private var windowSubtitle: String {
        store.activeSession?.project ?? ""
    }

}

/// Embeds the existing LauncherView. The Launcher still owns the new-session
/// flow; on Start it calls back into the store via a closure binding (set up
/// in PR 2 inside LauncherView). For PR 1/2 we feed it a temporary AppState.
private struct DetailLauncher: View {
    @Bindable var store: SessionStore
    @State private var localAppState = AppState()

    var body: some View {
        LauncherView(appState: localAppState, compactMode: true)
            .onChange(of: localAppState.screen) {
                // The Launcher uses an AppState-based screen transition. When
                // it flips to .session we hand off to the SessionStore, which
                // creates a fresh OpenSession with the same params.
                if localAppState.screen == .session {
                    store.openNew(
                        directory: localAppState.workingDirectory,
                        resumeId: localAppState.resumeSessionId,
                        sessionTitle: localAppState.resumeSessionTitle,
                        model: localAppState.model,
                        effortLevel: localAppState.effortLevel,
                        permissionMode: localAppState.permissionMode,
                        remoteHost: localAppState.remoteHost
                    )
                    // Reset the local appState so the next Start works again
                    localAppState.backToLauncher()
                }
            }
    }
}
