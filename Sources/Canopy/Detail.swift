import SwiftUI

/// The detail pane of the single-window shell. Renders N horizontal panes
/// (HStack of PaneHeaderStrip + SessionContainer / DetailLauncher). When
/// `store.panes` is empty, falls through to the launcher (fresh launch).
///
/// Only the focused pane's session drives the window title / subtitle.
/// WebViewContainer wraps a host NSView and swaps the WKWebView subview
/// in-place when its bound OpenSession changes (~10–30 ms), so DOM state
/// survives across switches without a SwiftUI re-mount.
struct Detail: View {
    @Bindable var store: SessionStore

    @ViewBuilder
    var body: some View {
        Group {
            if store.panes.isEmpty {
                // No pane yet: fall through to the launcher (fresh launch,
                // nothing selected). Once the user picks a session the
                // first pane is created via SessionStore.openInFocusedPane.
                DetailLauncher(store: store)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(store.panes.enumerated()), id: \.element.id) { index, pane in
                        if index > 0 {
                            PaneDivider(store: store, leftIndex: index - 1)
                        }
                        paneCell(pane: pane, index: index)
                            .frame(width: pane.preferredWidth)
                    }
                }
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

    @ViewBuilder
    private func paneCell(pane: PaneSlot, index: Int) -> some View {
        Group {
            switch pane.content {
            case .session(let sessionId):
                if let session = store.openSessions.first(where: { $0.id == sessionId }) {
                    VStack(spacing: 0) {
                        PaneHeaderStrip(
                            title: session.title.isEmpty ? "Untitled" : session.title,
                            project: session.project,
                            showCloseButton: store.panes.count > 1,
                            onClose: { store.closePane(at: index) }
                        )
                        SessionContainer(session: session) { _ in
                            store.closeSession(session.id)
                        }
                        .id(session.id)
                    }
                } else {
                    // Session was closed under us; pane should have been auto-removed
                    // via removePanesForClosedSession. Render an empty placeholder
                    // rather than crashing.
                    Color(nsColor: .windowBackgroundColor)
                }
            case .launcher:
                VStack(spacing: 0) {
                    PaneHeaderStrip(
                        title: "New Session",
                        project: "",
                        showCloseButton: store.panes.count > 1,
                        onClose: { store.closePane(at: index) }
                    )
                    DetailLauncher(store: store)
                }
            }
        }
        .overlay(focusBorder(active: index == store.focusedPaneIndex))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { store.setFocusedPaneIndex(index) })
    }

    private func focusBorder(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 2)
            .animation(.easeInOut(duration: 0.1), value: active)
            .allowsHitTesting(false)
    }

    private var windowTitle: String {
        guard let pane = store.focusedPane else { return "Canopy" }
        switch pane.content {
        case .session(let id):
            guard let session = store.openSessions.first(where: { $0.id == id }),
                  !session.title.isEmpty else { return "Canopy" }
            return session.title
        case .launcher:
            return "New Session"
        }
    }

    private var windowSubtitle: String {
        guard let pane = store.focusedPane else { return "" }
        if case .session(let id) = pane.content,
           let session = store.openSessions.first(where: { $0.id == id }) {
            return session.project
        }
        return ""
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
