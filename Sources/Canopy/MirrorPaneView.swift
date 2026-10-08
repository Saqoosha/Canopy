import SwiftUI
import WebKit
import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorPane")

/// A pane showing another Mac's session: the same WKWebView `WebViewContainer`
/// builds, driven over TCP by `RemoteMirrorBridge` instead of by a shim.
/// Reuses `SessionWebViewHost` so a pane swap is the same in-place subview
/// move, and the two-hosts-one-webview re-adoption rule holds here too.
struct MirrorPaneView: NSViewRepresentable {
    let session: OpenSession
    /// Called once with a user-facing message when the attach is refused or the
    /// socket drops before `attach_ok`; the caller closes the pane.
    let onFailure: (String) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, SessionWebViewHostOwner {
        var consoleHandler: ConsoleLogHandler?
        var linkHandler: LinkClickHandler?
        var inputWidthHandler: InputWidthMessageHandler?
        var lastBoundSessionId: OpenSession.ID?
        var reportedMissingPairing = false
        weak var session: OpenSession?

        /// See `SessionWebViewHost.owner`.
        func reclaim(_ webView: WKWebView) {
            guard webView.uiDelegate !== self || webView.navigationDelegate !== self else { return }
            logger.notice("Host re-pointed mirror webview delegates at its own coordinator (ui was \(SessionWebViewHost.delegateState(webView.uiDelegate, owner: self), privacy: .public), navigation was \(SessionWebViewHost.delegateState(webView.navigationDelegate, owner: self), privacy: .public))")
            webView.navigationDelegate = self
            webView.uiDelegate = self
            // When the other host was dismantled while holding this webview, `dismantleNSView` took
            // the script handlers too. Without `vscodeHost` the page's `init` never reaches the
            // bridge and the pane stays white (seen on a remote Mac after a daemon restart).
            if let session, session.webView === webView, let bridge = RemoteMirrorBridge.bridge(for: webView) {
                registerHandlers(on: webView, bridge: bridge, session: session)
            }
        }

        func registerHandlers(on webView: WKWebView, bridge: RemoteMirrorBridge, session: OpenSession) {
            let ucc = webView.configuration.userContentController
            for name in ["vscodeHost", "consoleLog", "canopyLink", InputWidthProbe.messageHandlerName] {
                ucc.removeScriptMessageHandler(forName: name)
            }
            let consoleHandler = ConsoleLogHandler()
            let linkHandler = LinkClickHandler(workingDirectory: session.origin.workingDirectory, opensLocalFiles: session.isDaemonHosted)
            let inputWidthHandler = InputWidthMessageHandler(statusBarData: session.statusBar)
            ucc.add(consoleHandler, name: "consoleLog")
            ucc.add(linkHandler, name: "canopyLink")
            ucc.add(inputWidthHandler, name: InputWidthProbe.messageHandlerName)
            ucc.add(bridge, name: "vscodeHost")
            self.consoleHandler = consoleHandler
            self.linkHandler = linkHandler
            self.inputWidthHandler = inputWidthHandler
            self.session = session
            webView.navigationDelegate = self
            webView.uiDelegate = self
        }

        /// Retry restarts the session, which rebuilds the webview and re-attaches.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            session?.connection.status = .reconnectFailed
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               (url.scheme == "http" || url.scheme == "https"),
               navigationAction.navigationType == .linkActivated
            {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // Safety net: block file:// link navigations that bypass JS interception
            if let url = navigationAction.request.url,
               url.scheme == "file",
               navigationAction.navigationType == .linkActivated
            {
                logger.warning("Blocked file:// navigation: \(url.path, privacy: .public)")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Handle target="_blank" links
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https"
            {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("Provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SessionWebViewHost {
        let host = SessionWebViewHost()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.owner = context.coordinator
        context.coordinator.session = session
        SessionWebViewHost.install(webView(coordinator: context.coordinator), in: host)
        context.coordinator.lastBoundSessionId = session.id
        let target = session.webView
        let sessionId = session.id
        DispatchQueue.main.async {
            WebViewContainer.focusIfThisPaneIsFocused(target, sessionId: sessionId)
        }
        return host
    }

    func updateNSView(_ host: SessionWebViewHost, context: Context) {
        guard session.id != context.coordinator.lastBoundSessionId else {
            if let webView = session.webView, let bridge = session.mirrorBridge, webView.superview !== host {
                host.adoptExpectedWebViewIfNeeded()
                registerHandlers(on: webView, bridge: bridge, coordinator: context.coordinator)
            } else {
                host.adoptExpectedWebViewIfNeeded()
            }
            return
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        SessionWebViewHost.install(webView(coordinator: context.coordinator), in: host)
        context.coordinator.lastBoundSessionId = session.id
    }

    static func dismantleNSView(_ host: SessionWebViewHost, coordinator: Coordinator) {
        for sub in host.subviews {
            guard let wk = sub as? WKWebView else {
                sub.removeFromSuperview()
                continue
            }
            // The session still holds this webview (another host takes it over, or the pane only swapped
            // away): stripping it would drop what the page posts meanwhile, a restart's `init` included.
            if coordinator.session?.webView === wk {
                logger.notice("[mirror-pane] dismantle left the live webview's handlers in place")
            } else {
                wk.navigationDelegate = nil
                wk.uiDelegate = nil
                let ucc = wk.configuration.userContentController
                for name in ["vscodeHost", "consoleLog", "canopyLink", InputWidthProbe.messageHandlerName] {
                    ucc.removeScriptMessageHandler(forName: name)
                }
            }
            sub.removeFromSuperview()
        }
    }

    /// Registers this pane's script message handlers on `webView`, replacing
    /// any left from an earlier mount — `dismantleNSView` removes them.
    private func registerHandlers(on webView: WKWebView, bridge: RemoteMirrorBridge, coordinator: Coordinator) {
        coordinator.registerHandlers(on: webView, bridge: bridge, session: session)
    }

    /// Where this pane attaches: another Mac over Tailscale, or this Mac's daemon.
    private func attachTarget() -> (endpoint: MirrorEndpoint, token: String, machine: String)? {
        if let target = session.origin.mirrorTarget {
            guard let token = MirrorAccess.peerToken(machineId: target.machineId) else { return nil }
            return (.tcp(host: target.host, port: target.port), token, session.statusBar.mirrorMachine ?? target.machineId)
        }
        guard session.isDaemonHosted else { return nil }
        return (.unix(path: DaemonPaths.current), "", "this Mac")
    }

    /// The cached webview when the session already has one; otherwise a fresh
    /// webview and bridge, attached in the order the bridge requires:
    /// socket ready → `attach` → page load.
    private func webView(coordinator: Coordinator) -> WKWebView {
        if let cached = session.webView, let bridge = session.mirrorBridge {
            registerHandlers(on: cached, bridge: bridge, coordinator: coordinator)
            return cached
        }
        // Waiting for this Mac's daemon to come up; that wait attaches the bridge.
        if let cached = session.webView, session.isDaemonHosted { return cached }
        guard let target = attachTarget() else {
            logger.error("[mirror-pane] no pairing for \(session.origin.mirrorTarget?.machineId ?? "nil", privacy: .public)")
            if !coordinator.reportedMissingPairing {
                coordinator.reportedMissingPairing = true
                let machine = session.statusBar.mirrorMachine ?? "this Mac"
                DispatchQueue.main.async {
                    onFailure("No password stored for \(machine). Paste its connection in Settings › Remote.")
                }
            }
            return WKWebView()
        }
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        WebViewContainer.addSessionUserScripts(to: ucc)
        // Retained by the configuration for the webview's life.
        let assetHandler = MirrorAssetSchemeHandler()
        config.setURLSchemeHandler(assetHandler, forURLScheme: MirrorConnection.assetScheme)
        let webView = SessionWKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        session.webView = webView

        if session.isDaemonHosted, !DaemonPaths.socketIsLive(path: DaemonPaths.current) {
            Task { @MainActor [session, onFailure] in
                let running = await DaemonSupervisor.ensureRunning()
                // The pane may have been closed or remounted during the wait; then this attempt is moot.
                guard session.webView === webView else { return }
                guard running else {
                    onFailure("This Mac's session service did not start. Quit and reopen Canopy to try again.")
                    return
                }
                attachBridge(to: webView, target: target, assetHandler: assetHandler, coordinator: coordinator)
            }
            return webView
        }
        attachBridge(to: webView, target: target, assetHandler: assetHandler, coordinator: coordinator)
        return webView
    }

    /// Opens the bridge, then wires its callbacks and the page's handlers to it.
    private func attachBridge(to webView: WKWebView, target: (endpoint: MirrorEndpoint, token: String, machine: String),
                              assetHandler: MirrorAssetSchemeHandler, coordinator: Coordinator) {
        let bridge = RemoteMirrorBridge(endpoint: target.endpoint, sessionId: session.resumeId, key: session.daemonKey,
                                        token: target.token, webView: webView, fetchesImages: true,
                                        open: session.isDaemonHosted ? session.daemonOpenRequest : session.pendingMirrorOpen,
                                        resumeCwd: session.isDaemonHosted ? session.origin.workingDirectory.path : nil)
        assetHandler.bridge = bridge
        registerHandlers(on: webView, bridge: bridge, coordinator: coordinator)
        let machineName = target.machine
        bridge.onStatus = { [weak session] frame in
            guard let session else { return }
            MirrorStatusFrame.apply(frame, to: session.statusBar)
            // Only the daemon's shim writes accountName; this Mac's sync already knows the account.
            if session.isDaemonHosted { session.statusBar.accountName = session.claudeAccount?.name }
        }
        let ownAccountFromThisMac = session.isDaemonHosted
        bridge.onUsage = { [weak bridge] frame in
            guard let bridge else { return }
            // Assigned even when nil, so an origin that moved to this Mac's account drops its block.
            bridge.usageKey = MirrorUsageFrame.key(forFrame: frame, localEmail: ClaudeAccountInfo.current()?.email)
            guard let rateLimits = frame["rate_limits"] as? [String: Any] else { return }
            if let key = bridge.usageKey {
                SharedRateLimitData.shared.account(for: key).updateFromRawUsage(rateLimits)
            } else if ownAccountFromThisMac, MirrorUsageFrame.isUsageFrame(frame) {
                // This Mac's own account, from this Mac's daemon only (another Mac's cache can be older).
                // The GUI fetches it just once at launch; the shims and the 10-minute refresh live in canopyd.
                SharedRateLimitData.shared.local.updateFromRawUsage(rateLimits)
            }
        }
        bridge.onFileFrame = { [weak session] frame in
            session?.fileTransfer.handle(frame)
        }
        bridge.onUIFrame = { [weak bridge, weak webView] frame in
            switch frame {
            case .showContent(let title, let content, let startLine, let endLine):
                ContentViewer.show(content: content, title: title, in: webView, startLine: startLine, endLine: endLine)
            case .recap(let text):
                if let webView { ShimProcess.injectRecap(text, into: webView) }
            case .errorBanner(let message):
                if let webView { ShimProcess.injectErrorBanner(message, into: webView) }
            case .alert(let requestId, let message, let severity, let buttons):
                let alert = NSAlert()
                alert.messageText = message
                alert.alertStyle = severity == "error" ? .critical : severity == "warning" ? .warning : .informational
                buttons.forEach { alert.addButton(withTitle: $0) }
                alert.addButton(withTitle: "Dismiss")
                let button = MirrorUIAlert.button(response: alert.runModal().rawValue, buttons: buttons)
                guard let bridge else {
                    logger.notice("alert \(requestId, privacy: .public) answered after its pane closed; the session's client left, so it was dismissed there")
                    return
                }
                bridge.sendUIAnswer(MirrorUIAnswer(requestId: requestId, button: button))
            case .notify(let title, let body):
                guard !NSApp.isActive else { return }
                SessionNotifier.post(title: title, body: body)
            }
        }
        let isDaemon = session.isDaemonHosted
        bridge.onOutcome = { [weak session, weak bridge] outcome in
            guard let session else { return }
            switch outcome {
            case .attached:
                session.status = .live
                session.pendingMirrorOpen = nil
                if let hostId = bridge?.hostSessionId {
                    session.mirrorHostSessionId = hostId
                    if isDaemon { session.daemonKey = hostId }
                }
                if let remote = bridge?.extensionVersion, let local = CCExtension.extensionVersion(), remote != local {
                    logger.notice("[mirror-pane] extension \(local, privacy: .public) here, \(remote, privacy: .public) on \(machineName, privacy: .public)")
                }
            case .refused(let reason):
                let showRefusal: () -> Void
                if case .spawning = session.status, reason != MirrorOpenRequest.stoppedByClient {
                    if isDaemon, reason == MirrorOpenRequest.notOpenable, case .local(let folder) = session.origin {
                        showRefusal = { onFailure(SessionStore.localOpenFailureMessage(folder: folder)) }
                    } else {
                        showRefusal = { onFailure(SessionStore.mirrorFailureMessage(reason: reason, machineName: machineName)) }
                    }
                } else {
                    showRefusal = { onFailure(SessionStore.mirrorEndedMessage(reason: reason, machineName: machineName)) }
                }
                // Our own Stop Session ends this client too, attaching or not; held like a drop, discarded when the stop succeeds.
                if session.isStopping {
                    session.dropHeldByStop = showRefusal
                } else {
                    showRefusal()
                }
            case .dropped:
                session.fileTransfer.connectionDropped()
                let showDrop = { [weak session, weak bridge] in
                    guard let session else { return }
                    if case .spawning = session.status {
                        onFailure(isDaemon ? "Could not reach this Mac's session service."
                                           : "Could not reach \(machineName). Is its live mirror on?")
                    } else {
                        session.connection.status = .reconnectFailed
                        session.isThinking = false
                        session.isAsking = false
                        session.isWaiting = false
                        // Only a restart the daemon announced re-attaches on its own: any other drop
                        // may be a stop made elsewhere, which must not be undone. launchd starts the
                        // new build; `ensureRunning` asks launchd before starting one itself.
                        if bridge?.expectsRestart == true {
                            if isDaemon {
                                Task { @MainActor [weak session] in
                                    guard await DaemonSupervisor.ensureRunning(), let session,
                                          session.connection.status == .reconnectFailed else { return }
                                    logger.notice("[mirror-pane] session service restarted; re-attaching \(session.resumeId, privacy: .public)")
                                    SessionStore.shared?.restartSession(session.id, notifyDaemon: false)
                                }
                            } else if let target = session.origin.mirrorTarget {
                                // Another Mac's daemon: wait for its listener, since re-attaching puts the
                                // pane back in `.spawning`, where a refused connection closes it.
                                let waiting = ConnectionStatus.awaitingRestart(machine: machineName)
                                session.connection.status = waiting
                                Task { @MainActor [weak session] in
                                    let deadline = Date().addingTimeInterval(RestartReattach.budget)
                                    while Date() < deadline {
                                        guard session?.connection.status == waiting else { return }
                                        if await RestartReattach.listenerIsUp(host: target.host, port: target.port,
                                                                              timeout: RestartReattach.interval) {
                                            guard let current = session, current.connection.status == waiting else { return }
                                            logger.notice("[mirror-pane] \(machineName, privacy: .public) is back; re-attaching \(current.resumeId, privacy: .public)")
                                            // The new daemon starts with no sessions; one that still holds it ignores `open`.
                                            current.pendingMirrorOpen = .resume
                                            SessionStore.shared?.restartSession(current.id, notifyDaemon: false)
                                            return
                                        }
                                        try? await Task.sleep(for: .seconds(RestartReattach.interval))
                                    }
                                    guard let current = session, current.connection.status == waiting else { return }
                                    logger.notice("[mirror-pane] \(machineName, privacy: .public) did not come back within \(Int(RestartReattach.budget))s")
                                    current.connection.status = .reconnectFailed
                                }
                            }
                        }
                    }
                }
                // Our own Stop Session: `stopSession` replays this only if the stop fails.
                if session.isStopping {
                    session.dropHeldByStop = showDrop
                } else {
                    showDrop()
                }
            }
        }
        session.connection.onRetry = { [weak session] in
            guard let session else { return }
            // Re-attach only: a dropped connection is not a reason to restart the daemon's CLI.
            // After an announced restart the other Mac holds no sessions, so ask it to resume.
            if !isDaemon, session.mirrorBridge?.expectsRestart == true { session.pendingMirrorOpen = .resume }
            SessionStore.shared?.restartSession(session.id, notifyDaemon: false)
        }
        session.mirrorBridge = bridge
    }
}
