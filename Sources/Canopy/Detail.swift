import AppKit
import SwiftUI

/// The detail pane of the single-window shell. Renders N horizontal panes
/// (WeightedPaneLayout of PaneHeaderStrip + SessionContainer /
/// DetailLauncher bundles). When `store.panes` is empty, falls through to
/// the launcher (fresh launch).
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
                // Custom Layout: preferredWidth is a weight, divider drag
                // changes the ratio, window resize scales all panes
                // proportionally, per-pane minimum 100 pt.
                //
                // Each subview is one (paneCell + trailing PaneDivider)
                // bundle. WeightedPaneLayout places them with exact
                // pane-widths + divider-widths, and its sizeThatFits
                // returns the parent's proposed width verbatim so
                // NavigationSplitView doesn't try to grow the window to
                // fit an "ideal" content width — that was the runaway
                // feedback source.
                WeightedPaneLayout(
                    weights: store.panes.map(\.preferredWidth),
                    dividerWidth: SessionStore.paneDividerWidth,
                    minimumWidth: SessionStore.paneMinDragWidth
                ) {
                    ForEach(Array(store.panes.enumerated()), id: \.element.id) { index, pane in
                        HStack(spacing: 0) {
                            paneCell(pane: pane, index: index)
                                .frame(maxWidth: .infinity,
                                       maxHeight: .infinity,
                                       alignment: .topLeading)
                            if index < store.panes.count - 1 {
                                PaneDivider(store: store, leftIndex: index)
                                    .frame(width: SessionStore.paneDividerWidth)
                            }
                        }
                        // Flush pane headers: each pane extends up into the
                        // hidden-title-bar strip so PaneHeaderStrip sits
                        // level with the traffic lights. This MUST be on
                        // the layout's CHILDREN, not on any ancestor of
                        // WeightedPaneLayout: a safe-area-ignoring
                        // container above a custom Layout freezes child
                        // geometry commits during live window resize
                        // (macOS 26 SwiftUI bug — layout passes run with
                        // the new bounds but the WKWebView host and even
                        // native Texts keep their old frames; only pane
                        // add/close refreshed). Child-level ignore keeps
                        // the reclaim AND normal resize propagation.
                        .ignoresSafeArea(edges: .top)
                    }
                }
            }
        }
        // Align to top-leading so the multi-pane layout sits flush against
        // the sidebar edge instead of getting centered horizontally.
        // Overflow (window wider than the panes) stays on the trailing edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if let progress = store.teleporting {
                TeleportOverlay(progress: progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.teleporting)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        // Keep the toolbar's title item out of the reclaimed strip; the
        // window title (Mission Control / window lists) still comes from
        // navigationTitle.
        .toolbar(removing: .title)
    }

    @ViewBuilder
    private func paneCell(pane: PaneSlot, index: Int) -> some View {
        Group {
            switch pane.content {
            case .session(let sessionId):
                if let session = store.openSessions.first(where: { $0.id == sessionId }) {
                    VStack(spacing: 0) {
                        // Always show the pane header — one bar per pane,
                        // regardless of count. Duplication with the window
                        // title bar is avoided by keeping the title bar
                        // generic ("Canopy") in `windowTitle`.
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
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { store.setFocusedPaneIndex(index) })
    }

    private var windowTitle: String {
        // Multi-pane: pane headers already carry each pane's title, so
        // duplicating one in the title bar reads as noise. Keep the bar
        // generic and let the pane strips do the identification.
        if store.panes.count > 1 { return "Canopy" }
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
        if store.panes.count > 1 { return "" }
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
                    let target: SessionStore.PaneTarget =
                        NSEvent.modifierFlags.contains(.command) ? .newPane : .focused
                    store.openNew(
                        directory: localAppState.workingDirectory,
                        resumeId: localAppState.resumeSessionId,
                        sessionTitle: localAppState.resumeSessionTitle,
                        model: localAppState.model,
                        effortLevel: localAppState.effortLevel,
                        permissionMode: localAppState.permissionMode,
                        remoteHost: localAppState.remoteHost,
                        customApi: localAppState.customApi,
                        target: target
                    )
                    // Reset the local appState so the next Start works again
                    localAppState.backToLauncher()
                }
            }
    }
}
