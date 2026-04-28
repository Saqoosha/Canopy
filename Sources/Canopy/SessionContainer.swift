import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionContainer")

/// Renders one `OpenSession` in the detail pane: WebView (CC extension) + the
/// status bar at the bottom + a connection-state overlay.
///
/// Only the active SessionContainer is mounted in the detail pane.
/// `WebViewContainer` swaps the WKWebView subview in-place when its bound
/// OpenSession changes (~10–30 ms), so DOM state and the shim connection
/// survive across session switches.
struct SessionContainer: View {
    @Bindable var session: OpenSession
    var onCrash: ((Int32) -> Void)?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                WebViewContainer(
                    workingDirectory: session.origin.workingDirectory,
                    resumeSessionId: session.resumeId,
                    model: session.model,
                    effortLevel: session.effortLevel,
                    permissionMode: session.permissionMode,
                    sessionTitle: session.title,
                    statusBarData: session.statusBar,
                    remoteHost: session.origin.remoteHost,
                    connectionState: session.connection,
                    onCrash: { code in
                        logger.error("Session \(session.id.uuidString, privacy: .public) crashed (status \(code))")
                        session.status = .crashed(exitCode: code)
                        onCrash?(code)
                    },
                    boundSession: session
                )
                .overlay {
                    ConnectionOverlayView(
                        connectionState: session.connection,
                        onBackToLauncher: {
                            // In the sidebar shell there is no "back to launcher"
                            // button; users explicitly close via the × instead.
                            session.connection.status = .connected
                        }
                    )
                }
                .animation(.easeInOut(duration: 0.3), value: session.connection.isOverlayVisible)

                StatusBarView(data: session.statusBar)
            }

            // Starting overlay — covers the brief window between the user
            // clicking the row (selection swaps instantly) and the CC
            // extension's webview rendering its first frame. Without this,
            // the user sees a blank pane for 1–3 s and wonders if the click
            // landed.
            if case .spawning = session.status {
                SpawningOverlay(title: session.title, project: session.project)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.status == .spawning)
        .task(id: session.id) {
            // Boot the spawning state regardless of how the OpenSession was
            // created. Flip to .live a short delay after the webview HTML
            // load — long enough to mask the first paint, short enough that
            // the user perceives the click as instant.
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                if case .spawning = session.status {
                    session.status = .live
                }
            }
        }
    }
}

/// Lightweight placeholder shown over the WebView while the shim spawns.
private struct SpawningOverlay: View {
    let title: String
    let project: String

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting \(title)…")
                    .font(.headline)
                Text(project)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
