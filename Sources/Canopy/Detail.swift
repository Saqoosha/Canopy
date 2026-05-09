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
        // No ZStack around the launcher/session swap: WKWebView's NSView
        // could otherwise end up alongside the launcher in the same
        // NSHostingView and steal clicks on resize. The teleport overlay
        // sits in a separate `.overlay` so it never co-mounts with the
        // WebView host.
        Group {
            if case .session(let id) = store.selection,
               let session = store.openSessions.first(where: { $0.id == id }) {
                SessionContainer(session: session) { _ in
                    store.closeSession(session.id)
                }
                // `.id(session.id)` forces SwiftUI to re-mount the
                // SessionContainer when the active session changes. We
                // tried omitting it — `updateNSView` was supposed to
                // swap the WebView in place — but SwiftUI silently
                // refused to call `updateNSView` after the second
                // `openNew`, so sessions 2..N stayed invisible. The
                // `OpenSession.shim` / `OpenSession.webView` cache plus
                // `WebViewContainer.buildWebView`'s reuse path keep the
                // re-mount cheap (no shim restart, no HTML reload).
                .id(session.id)
            } else {
                DetailLauncher(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let progress = store.teleporting {
                TeleportOverlay(progress: progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.teleporting)
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

/// Full-pane overlay shown while a cloud session is being teleported. The
/// flow takes 2–10 s (shim spawn + JSONL download + optional `git checkout`)
/// and the underlying selection doesn't change until it completes, so without
/// this the user sees nothing happen after clicking the row.
private struct TeleportOverlay: View {
    let progress: SessionStore.TeleportProgress

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.92)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Teleporting \(progress.title)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !progress.project.isEmpty {
                    Text(progress.project)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(progress.stage.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: progress.stage)
            }
            .padding(24)
        }
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
                        remoteHost: localAppState.remoteHost,
                        customApi: localAppState.customApi
                    )
                    // Reset the local appState so the next Start works again
                    localAppState.backToLauncher()
                }
            }
    }
}
