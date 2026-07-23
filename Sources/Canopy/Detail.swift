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
    @State private var leftPaneHeaderChromeAvoidance: CGFloat = 0

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
        .background {
            PaneHeaderChromeAvoidanceProbe(leadingInset: $leftPaneHeaderChromeAvoidance)
        }
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
                            leadingChromeAvoidance: index == 0 ? leftPaneHeaderChromeAvoidance : 0,
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
                        leadingChromeAvoidance: index == 0 ? leftPaneHeaderChromeAvoidance : 0,
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

/// Observes the window's standard buttons + this-window layout updates and
/// publishes the extra leading inset the *leftmost* pane header needs so its
/// title never sits under the traffic-light cluster + collapsed-sidebar
/// toggle. Threaded to `PaneHeaderStrip.leadingChromeAvoidance` from
/// `Detail.paneCell` only when `index == 0` — passing the same value to
/// non-leftmost panes would visibly misalign them.
///
/// Attach as a `.background { }` of the detail column so the probe view's
/// frame equals the detail column's frame (used as `paneMinX`). Placing it
/// in an `.overlay` or on a smaller/larger container would silently return
/// the wrong leading inset.
///
/// Mechanism: observes `NSWindow.didResize` / `didBecomeKey` / `didUpdate`
/// on this window only, coalesces multiple signals into one main-queue
/// recompute per runloop tick, and republishes via the binding — rounded up
/// and dead-banded at 0.5pt to prevent SwiftUI update storms.
private struct PaneHeaderChromeAvoidanceProbe: NSViewRepresentable {
    @Binding var leadingInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingInset: $leadingInset)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        context.coordinator.probeView = view
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.leadingInset = $leadingInset
        context.coordinator.probeView = nsView
        context.coordinator.attach(to: nsView.window)
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var leadingInset: Binding<CGFloat>

        weak var probeView: NSView?
        private weak var window: NSWindow?
        private var recomputeScheduled = false

        // Shared source of truth with PaneHeaderStrip so this probe's math
        // stays in lockstep with the header's actual padding.
        private static var headerBaseLeadingPadding: CGFloat { PaneHeaderStrip.baseLeadingPadding }
        private static let buttonTrailingMargin: CGFloat = 12
        // Empirical clearance the NavigationSplitView sidebar-toggle button
        // needs to the right of the traffic lights when the sidebar is
        // collapsed. If macOS changes toggle geometry, re-measure this.
        private static let collapsedSidebarToggleClearance: CGFloat = 64

        init(leadingInset: Binding<CGFloat>) {
            self.leadingInset = leadingInset
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to newWindow: NSWindow?) {
            if window === newWindow {
                scheduleRecompute()
                return
            }

            NotificationCenter.default.removeObserver(self)
            window = newWindow

            guard let newWindow else {
                publish(0)
                return
            }

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(observedChromeDidChange(_:)),
                name: NSWindow.didResizeNotification,
                object: newWindow
            )
            center.addObserver(
                self,
                selector: #selector(observedChromeDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: newWindow
            )
            // Sidebar toggle / drag runs through NSSplitView.didResizeSubviewsNotification.
            // NSWindow.didUpdateNotification alone missed these because updateWindows
            // ticks only when the app processes an event — so during a pure sidebar
            // animation the header stayed stale until the user moved the mouse. We
            // register with `object: nil` (the split view isn't guaranteed to be in
            // the view hierarchy at attach time) and filter cross-window notifications
            // in the handler via `split.window === self.window`.
            center.addObserver(
                self,
                selector: #selector(observedChromeDidChange(_:)),
                name: NSSplitView.didResizeSubviewsNotification,
                object: nil
            )

            scheduleRecompute()
        }

        @objc private func observedChromeDidChange(_ notification: Notification) {
            if let split = notification.object as? NSSplitView, split.window !== window {
                return
            }
            scheduleRecompute()
        }

        private func scheduleRecompute() {
            guard !recomputeScheduled else { return }
            recomputeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recomputeScheduled = false
                self.recompute()
            }
        }

        private func recompute() {
            guard let window, let probeView else {
                publish(0)
                return
            }
            publish(Self.chromeAvoidance(window: window, probeView: probeView))
        }

        private func publish(_ value: CGFloat) {
            let rounded = value.rounded(.up)
            guard abs(leadingInset.wrappedValue - rounded) > 0.5 else { return }
            leadingInset.wrappedValue = rounded
        }

        private static func chromeAvoidance(window: NSWindow, probeView: NSView) -> CGFloat {
            let buttonMaxX = [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ]
                .compactMap { buttonFrameInContentCoordinates(window: window, type: $0)?.maxX }
                .max()

            guard let buttonMaxX, buttonMaxX > 0,
                  let contentView = window.contentView
            else { return 0 }

            let paneMinX = probeView.convert(probeView.bounds, to: contentView).minX
            return max(
                0,
                buttonMaxX
                    + collapsedSidebarToggleClearance
                    + buttonTrailingMargin
                    - paneMinX
                    - headerBaseLeadingPadding
            )
        }

        private static func buttonFrameInContentCoordinates(
            window: NSWindow,
            type: NSWindow.ButtonType
        ) -> CGRect? {
            guard let button = window.standardWindowButton(type),
                  !button.isHidden,
                  let superview = button.superview,
                  let contentView = window.contentView
            else { return nil }

            let frameInWindow = superview.convert(button.frame, to: nil)
            return contentView.convert(frameInWindow, from: nil)
        }
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
