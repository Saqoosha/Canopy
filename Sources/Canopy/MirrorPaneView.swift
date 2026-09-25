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
            if let wk = sub as? WKWebView {
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
        let ucc = webView.configuration.userContentController
        for name in ["vscodeHost", "consoleLog", "canopyLink", InputWidthProbe.messageHandlerName] {
            ucc.removeScriptMessageHandler(forName: name)
        }
        let consoleHandler = ConsoleLogHandler()
        let linkHandler = LinkClickHandler(workingDirectory: session.origin.workingDirectory, opensLocalFiles: false)
        let inputWidthHandler = InputWidthMessageHandler(statusBarData: session.statusBar)
        ucc.add(consoleHandler, name: "consoleLog")
        ucc.add(linkHandler, name: "canopyLink")
        ucc.add(inputWidthHandler, name: InputWidthProbe.messageHandlerName)
        ucc.add(bridge, name: "vscodeHost")
        coordinator.consoleHandler = consoleHandler
        coordinator.linkHandler = linkHandler
        coordinator.inputWidthHandler = inputWidthHandler
        coordinator.session = session
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
    }

    /// The cached webview when the session already has one; otherwise a fresh
    /// webview and bridge, attached in the order the bridge requires:
    /// socket ready → `attach` → page load.
    private func webView(coordinator: Coordinator) -> WKWebView {
        if let cached = session.webView, let bridge = session.mirrorBridge {
            registerHandlers(on: cached, bridge: bridge, coordinator: coordinator)
            return cached
        }
        guard let target = session.origin.mirrorTarget,
              let token = MirrorAccess.peerToken(machineId: target.machineId) else {
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

        let bridge = RemoteMirrorBridge(host: target.host, port: target.port, sessionId: session.resumeId, token: token,
                                        webView: webView, fetchesImages: true)
        assetHandler.bridge = bridge
        registerHandlers(on: webView, bridge: bridge, coordinator: coordinator)
        let machineName = session.statusBar.mirrorMachine ?? target.machineId
        bridge.onStatus = { [weak session] frame in
            guard let session else { return }
            MirrorStatusFrame.apply(frame, to: session.statusBar)
        }
        bridge.onUsage = { [weak bridge] frame in
            guard let bridge else { return }
            // Assigned even when nil, so an origin that moved to this Mac's account drops its block.
            bridge.usageKey = MirrorUsageFrame.key(forFrame: frame, localEmail: ClaudeAccountInfo.current()?.email)
            guard let key = bridge.usageKey, let rateLimits = frame["rate_limits"] as? [String: Any] else { return }
            SharedRateLimitData.shared.account(for: key).updateFromRawUsage(rateLimits)
        }
        bridge.onFileFrame = { [weak session] frame in
            session?.fileTransfer.handle(frame)
        }
        bridge.onOutcome = { [weak session, weak bridge] outcome in
            guard let session else { return }
            switch outcome {
            case .attached:
                session.status = .live
                if let remote = bridge?.extensionVersion, let local = CCExtension.extensionVersion(), remote != local {
                    logger.notice("[mirror-pane] extension \(local, privacy: .public) here, \(remote, privacy: .public) on \(machineName, privacy: .public)")
                }
            case .refused(let reason):
                onFailure(SessionStore.mirrorFailureMessage(reason: reason, machineName: machineName))
            case .dropped:
                session.fileTransfer.connectionDropped()
                if case .spawning = session.status {
                    onFailure("Could not reach \(machineName). Is its live mirror on?")
                } else {
                    session.connection.status = .reconnectFailed
                    session.isThinking = false
                    session.isAsking = false
                    session.isWaiting = false
                }
            }
        }
        session.connection.onRetry = { [weak session] in
            guard let session else { return }
            SessionStore.shared?.restartSession(session.id)
        }
        session.webView = webView
        session.mirrorBridge = bridge
        return webView
    }
}
