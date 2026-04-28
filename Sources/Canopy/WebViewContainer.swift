import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "WebView")

struct WebViewContainer: NSViewRepresentable {
    let workingDirectory: URL
    var resumeSessionId: String?
    var model: String?
    var effortLevel: String?
    var permissionMode: PermissionMode = .acceptEdits
    var sessionTitle: String?
    var statusBarData: StatusBarData?
    var remoteHost: String?
    var connectionState: ConnectionState?
    var onCrash: ((Int32) -> Void)?
    /// When set, the coordinator writes the spawned `ShimProcess` and `WKWebView`
    /// back to this OpenSession so `SessionStore.closeSession` can find them.
    /// Used by the single-window-sidebar shell. Legacy multi-window code leaves
    /// this nil and the refs stay private to the Coordinator.
    var boundSession: OpenSession?

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, ShimProcessDelegate {
        var shimProcess: ShimProcess?
        var consoleHandler: ConsoleLogHandler?
        var linkHandler: LinkClickHandler?
        var connectionState: ConnectionState?
        var onCrash: ((Int32) -> Void)?
        /// Retained independently so reconnect can access it after shimProcess is nil'd.
        weak var currentWebView: WKWebView?
        /// Tracks which OpenSession the host is currently bound to so
        /// `updateNSView` can detect a swap.
        var lastBoundSessionId: UUID?

        // Params needed to create a new ShimProcess on reconnect
        var workingDirectory: URL?
        var remoteHost: String?
        var model: String?
        var effortLevel: String?
        var permissionMode: PermissionMode = .acceptEdits
        var statusBarData: StatusBarData?

        private var reconnectTimer: Timer?
        private var reconnectAttempt = 0
        private var lastDisconnectedSessionId: String?
        private static let maxReconnectAttempts = 3
        private static let backoffIntervals: [TimeInterval] = [3, 6, 12]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("Page loaded successfully")
            shimProcess?.webViewDidFinishLoad()
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

        private var lastCrashReload: Date = .distantPast

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let now = Date()
            guard now.timeIntervalSince(lastCrashReload) > 5 else {
                logger.error("WebContent crashed again within 5s — not reloading")
                return
            }
            lastCrashReload = now
            logger.error("WebContent process terminated — reloading")
            webView.reload()
        }

        // MARK: - ShimProcessDelegate

        func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String) {
            logger.info("SSH disconnected, starting reconnection for session \(sessionId, privacy: .public)")
            lastDisconnectedSessionId = sessionId
            reconnectAttempt = 0
            connectionState?.status = .reconnecting(attempt: 1)
            connectionState?.onRetry = { [weak self] in
                self?.retryReconnect()
            }
            attemptReconnect(sessionId: sessionId)
        }

        func shimProcessDidCrash(_ shim: ShimProcess, status: Int32) {
            logger.error("Shim crashed (status \(status)), returning to launcher")
            onCrash?(status)
        }

        private func attemptReconnect(sessionId: String) {
            reconnectAttempt += 1
            let attempt = reconnectAttempt

            if attempt > Self.maxReconnectAttempts {
                logger.error("All reconnect attempts exhausted")
                connectionState?.status = .reconnectFailed
                return
            }

            let delay = Self.backoffIntervals[min(attempt - 1, Self.backoffIntervals.count - 1)]
            logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) in \(delay)s")
            connectionState?.status = .reconnecting(attempt: attempt)

            reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.doReconnect(sessionId: sessionId)
            }
        }

        private func doReconnect(sessionId: String) {
            guard let webView = currentWebView,
                  let workingDirectory,
                  let remoteHost
            else {
                logger.error("Reconnect failed: missing webView or params")
                connectionState?.status = .reconnectFailed
                return
            }

            // Clean up old shim's message handler
            let ucc = webView.configuration.userContentController
            ucc.removeScriptMessageHandler(forName: "vscodeHost")
            shimProcess = nil

            // Create new ShimProcess with --resume
            let newShim = ShimProcess(
                workingDirectory: workingDirectory,
                resumeSessionId: sessionId,
                model: model,
                effortLevel: effortLevel,
                permissionMode: permissionMode,
                sessionTitle: nil,
                statusBarData: statusBarData,
                remoteHost: remoteHost
            )
            newShim.delegate = self
            newShim.webView = webView
            ucc.add(newShim, name: "vscodeHost")

            if newShim.start() {
                logger.info("Reconnect succeeded")
                shimProcess = newShim
                reconnectAttempt = 0
                connectionState?.status = .connected
                newShim.webViewDidFinishLoad()
            } else {
                logger.error("Reconnect attempt \(self.reconnectAttempt) failed: shim start returned false")
                ucc.removeScriptMessageHandler(forName: "vscodeHost")
                attemptReconnect(sessionId: sessionId)
            }
        }

        func cancelReconnect() {
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            reconnectAttempt = 0
        }

        private func retryReconnect() {
            guard let sessionId = lastDisconnectedSessionId else {
                logger.warning("retryReconnect: no session ID available")
                return
            }
            cancelReconnect()
            connectionState?.status = .reconnecting(attempt: 1)
            attemptReconnect(sessionId: sessionId)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// We return an NSView host that contains the WKWebView as a subview.
    /// Wrapping in a host lets us swap WKWebViews in-place (via
    /// `updateNSView`) when `boundSession` changes, without the heavy
    /// SwiftUI `.id(...)` re-mount cycle. The WKWebView itself stays
    /// alive on `OpenSession.webView`.
    func makeNSView(context: Context) -> NSView {
        let host = SessionWebViewHost()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        attachWebView(to: host, coordinator: context.coordinator)
        context.coordinator.lastBoundSessionId = boundSession?.id
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        // Swap the inner WKWebView when the session bound to this view
        // changes. Mismatch can happen because the SessionContainer's
        // session parameter changes without SwiftUI re-mounting.
        let newId = boundSession?.id
        guard newId != context.coordinator.lastBoundSessionId else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        // Reset coordinator state — the previous webView's delegates and
        // handlers were tied to the old session.
        context.coordinator.cancelReconnect()
        context.coordinator.shimProcess = nil
        context.coordinator.consoleHandler = nil
        context.coordinator.linkHandler = nil
        attachWebView(to: host, coordinator: context.coordinator)
        context.coordinator.lastBoundSessionId = newId
    }

    /// Build (or fetch cached) WKWebView for `boundSession` and add it
    /// as a subview of the host, filling its bounds.
    private func attachWebView(to host: NSView, coordinator: Coordinator) {
        let webView = buildWebView(coordinator: coordinator)
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    private func buildWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()

        ucc.addUserScript(WKUserScript(
            source: Self.consoleCapture,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        ucc.addUserScript(WKUserScript(
            source: VSCodeStub.javascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        ucc.addUserScript(WKUserScript(
            source: Self.linkClickInterception,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let consoleHandler = ConsoleLogHandler()
        ucc.add(consoleHandler, name: "consoleLog")

        let linkHandler = LinkClickHandler(workingDirectory: workingDirectory)
        ucc.add(linkHandler, name: "canopyLink")

        // Reuse an existing shim when the OpenSession already owns one.
        // This prevents the orphan-shim bug: SwiftUI runs makeNSView twice
        // for the same SessionContainer (opacity transitions in Detail's
        // ZStack), and creating a fresh shim each time leaves the first
        // one CLI-connected but UI-disconnected.
        //
        // We also have to short-circuit BEFORE the per-handler `ucc.add`
        // calls — adding a fresh ShimProcess would still happen (and waste
        // a Node subprocess at construction time) if we left the original
        // initializer call in the else branch. Instead, allocate a new
        // shim only when none exists.
        let shim: ShimProcess
        let isFreshShim: Bool
        if let existing = boundSession?.shim {
            shim = existing
            isFreshShim = false
            // Re-bind to the new webView's userContentController. The old
            // ucc has the shim registered as `vscodeHost`; the new ucc is
            // a different instance and needs the same registration.
        } else {
            shim = ShimProcess(
                workingDirectory: workingDirectory,
                resumeSessionId: resumeSessionId,
                model: model,
                effortLevel: effortLevel,
                permissionMode: permissionMode,
                sessionTitle: sessionTitle,
                statusBarData: statusBarData,
                remoteHost: remoteHost
            )
            isFreshShim = true
        }
        shim.delegate = coordinator
        ucc.add(shim, name: "vscodeHost")
        coordinator.shimProcess = shim
        coordinator.consoleHandler = consoleHandler
        coordinator.linkHandler = linkHandler
        coordinator.connectionState = connectionState
        coordinator.workingDirectory = workingDirectory
        coordinator.remoteHost = remoteHost
        coordinator.model = model
        coordinator.effortLevel = effortLevel
        coordinator.permissionMode = permissionMode
        coordinator.statusBarData = statusBarData
        coordinator.onCrash = onCrash

        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Reuse an existing WKWebView when the OpenSession already owns one.
        // Detail.swift now mounts only the active SessionContainer (the
        // 1×1-frame trick failed after window resizes), so swapping back to
        // a previously-opened session goes through this path. The WebView
        // is still strong-held by `OpenSession.webView`; we just need to
        // re-attach handlers to its existing userContentController.
        let webView: WKWebView
        let isFreshWebView: Bool
        if let cached = boundSession?.webView {
            webView = cached
            isFreshWebView = false
            // Replace handler set on the existing ucc — old shim's
            // registrations may still be there.
            let cachedUcc = webView.configuration.userContentController
            cachedUcc.removeScriptMessageHandler(forName: "vscodeHost")
            cachedUcc.removeScriptMessageHandler(forName: "consoleLog")
            cachedUcc.removeScriptMessageHandler(forName: "canopyLink")
            cachedUcc.add(consoleHandler, name: "consoleLog")
            cachedUcc.add(linkHandler, name: "canopyLink")
            cachedUcc.add(shim, name: "vscodeHost")
        } else {
            webView = WKWebView(frame: .zero, configuration: config)
            webView.isInspectable = true
            isFreshWebView = true
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        shim.webView = webView
        coordinator.currentWebView = webView
        if isFreshShim {
            if !shim.start() {
                logger.error("Shim start failed — no fallback available")
            }
        }
        if isFreshWebView {
            loadCCWebview(webView)
        }
        // Bind shim and webView to the OpenSession (canonical owner) so:
        //   - close button / status updates can reach the shim
        //   - re-mounting the SessionContainer reuses the same webView
        if let session = boundSession {
            session.shim = shim
            session.webView = webView
            shim.boundSession = session
        }
        return webView
    }

    /// Clean up handlers and detach the WKWebView subview from its host.
    /// In the sidebar shell we KEEP the WebView and ShimProcess alive —
    /// the OpenSession owns them. `SessionStore.closeSession` is the only
    /// path that stops the shim and releases the webView.
    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        coordinator.cancelReconnect()
        for sub in host.subviews {
            if let wk = sub as? WKWebView {
                wk.navigationDelegate = nil
                wk.uiDelegate = nil
                let ucc = wk.configuration.userContentController
                ucc.removeScriptMessageHandler(forName: "vscodeHost")
                ucc.removeScriptMessageHandler(forName: "consoleLog")
                ucc.removeScriptMessageHandler(forName: "canopyLink")
            }
            sub.removeFromSuperview()
        }
        if coordinator.shimProcess?.boundSession == nil {
            coordinator.shimProcess?.stop()
        }
        coordinator.shimProcess = nil
        coordinator.consoleHandler = nil
        coordinator.linkHandler = nil
        logger.info("WebView host dismantled (subview detached, retained by OpenSession)")
    }

    // MARK: - Load CC webview

    private func loadCCWebview(_ webView: WKWebView) {
        guard let extPath = CCExtension.extensionPath() else {
            webView.loadHTMLString(
                "<html><body style='background:#ffffff;color:#333;padding:40px;font-family:sans-serif'>"
                + "<h1>Canopy</h1><p>Claude Code extension not found. Install it in VSCode first.</p></body></html>",
                baseURL: nil
            )
            return
        }

        let webviewDir = extPath.appendingPathComponent("webview")
        let cssFile = webviewDir.appendingPathComponent("index.css")
        let jsFile = webviewDir.appendingPathComponent("index.js")

        logger.info("Extension path: \(extPath.path, privacy: .public)")
        logger.info("CSS exists: \(FileManager.default.fileExists(atPath: cssFile.path), privacy: .public)")
        logger.info("JS exists: \(FileManager.default.fileExists(atPath: jsFile.path), privacy: .public)")

        // Read bundled CSS/JS content for inline embedding
        // (Bundle.main is under /Applications, outside allowingReadAccessTo: homeDirectory,
        //  so we inline into the HTML instead of linking to external files)
        let overridesCSS = Self.readBundleResource("canopy-overrides", ext: "css") ?? ""
        if overridesCSS.isEmpty { logger.error("canopy-overrides.css not found in bundle") }
        let prismCSS = Self.readBundleResource("prism-canopy", ext: "css") ?? ""
        if prismCSS.isEmpty { logger.warning("prism-canopy.css not found in bundle — syntax highlighting disabled") }
        let prismJS = Self.readBundleResource("prism", ext: "js") ?? ""
        if prismJS.isEmpty { logger.warning("prism.js not found in bundle — syntax highlighting disabled") }

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>\(VSCodeStub.themeCSSVariables)</style>
          <link href="\(cssFile.absoluteString)" rel="stylesheet">
          <style>\(overridesCSS)</style>
          <style>\(prismCSS)</style>
        </head>
        <body class="vscode-light">
          <pre id="claude-error" style="display:none; position:fixed; top:0; left:0; right:0; z-index:9999; margin:0; padding:12px 16px; background:#fee2e2; color:#991b1b; font-size:13px; white-space:pre-wrap;"></pre>
          <script>new MutationObserver(function(){var e=document.getElementById('claude-error');if(e)e.style.display=e.textContent?'block':'none'}).observe(document.getElementById('claude-error'),{childList:true,characterData:true,subtree:true})</script>
          <div id="root"\(resumeSessionId.map { " data-initial-session=\"\($0)\"" } ?? "")\(Self.initialAuthStatusAttr())></div>
          <script src="\(jsFile.absoluteString)" type="module"></script>
          <script>\(prismJS)</script>
        </body>
        </html>
        """

        // Write HTML to Application Support
        let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Canopy")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let htmlFile = appSupportDir.appendingPathComponent("_canopy.html")
        do {
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write _canopy.html: \(error.localizedDescription, privacy: .public)")
            webView.loadHTMLString(
                "<html><body style='background:#fff;color:#333;padding:40px;font-family:sans-serif'>"
                + "<h1>Canopy Error</h1><p>Failed to write webview HTML: \(error.localizedDescription)</p></body></html>",
                baseURL: nil
            )
            return
        }
        // Allow read access to home directory (covers Application Support HTML and extension resources)
        let commonParent = FileManager.default.homeDirectoryForCurrentUser
        webView.loadFileURL(htmlFile, allowingReadAccessTo: commonParent)
    }

    // MARK: - Bundle Resource Reading

    /// Read a bundle resource's contents as a String.
    /// Returns `nil` if the resource is not found in the bundle.
    private static func readBundleResource(_ name: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Failed to read \(name).\(ext) from bundle: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Auth Status for HTML injection

    /// Build data-initial-auth-status attribute from macOS Keychain.
    /// The CC webview reads this from `<div id="root">` on startup for instant auth display.
    private static func initialAuthStatusAttr() -> String {
        guard let jsonStr = KeychainAuth.readAuthStatusJSON() else { return "" }
        return " data-initial-auth-status=\"\(jsonStr.replacingOccurrences(of: "\"", with: "&quot;"))\""
    }


    // MARK: - Link click interception JS

    /// Intercept non-http(s) <a> link clicks to prevent file:// navigations
    /// that crash WKWebView's WebContent process (sandbox restriction).
    /// Runs in bubble phase so React handlers (tool result links) take priority.
    private static let linkClickInterception = """
    (function() {
        document.addEventListener('click', function(e) {
            if (e.defaultPrevented) return;
            var link = e.target.closest('a[href]');
            if (!link) return;
            var href = link.getAttribute('href');
            if (!href || href === '#' || href.startsWith('javascript:') ||
                href.startsWith('http://') || href.startsWith('https://') ||
                href.startsWith('mailto:') || href.startsWith('tel:')) return;
            e.preventDefault();
            try { window.webkit.messageHandlers.canopyLink.postMessage(href); }
            catch(err) { console.error('[Canopy] canopyLink error:', err); }
        }, false);
    })();
    """

    // MARK: - Console capture JS

    private static let consoleCapture = """
    (function() {
        const origLog = console.log;
        const origError = console.error;
        const origWarn = console.warn;
        function send(level, args) {
            try {
                window.webkit.messageHandlers.consoleLog.postMessage({
                    level: level,
                    message: Array.from(args).map(a => {
                        try { return typeof a === 'object' ? JSON.stringify(a).substring(0, 500) : String(a); }
                        catch(e) { return String(a); }
                    }).join(' ')
                });
            } catch(e) {
                origError.apply(console, ['[Canopy console bridge error]', e]);
            }
        }
        console.log = function() { send('log', arguments); origLog.apply(console, arguments); };
        console.error = function() { send('error', arguments); origError.apply(console, arguments); };
        console.warn = function() { send('warn', arguments); origWarn.apply(console, arguments); };
        window.onerror = function(msg, src, line, col, err) {
            send('error', ['UNCAUGHT: ' + msg + ' at ' + src + ':' + line + ':' + col]);
        };
        window.onunhandledrejection = function(e) {
            send('error', ['UNHANDLED REJECTION: ' + (e.reason?.message || e.reason || e)]);
        };
    })();
    """
}

// MARK: - Link click handler

final class LinkClickHandler: NSObject, WKScriptMessageHandler {
    let workingDirectory: URL

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let href = message.body as? String else {
            logger.warning("LinkClickHandler: unexpected message type: \(type(of: message.body))")
            return
        }
        logger.info("Link clicked: \(href, privacy: .public)")

        // Strip fragment (#L42 etc.) and file:// scheme
        var path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? String(path.dropFirst(7))
        }

        // Try as absolute path first
        if path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        // Try relative to working directory
        let resolved = workingDirectory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.open(resolved)
            return
        }

        logger.warning("File not found: \(resolved.path, privacy: .public)")
    }
}

// MARK: - Console log handler

final class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any],
              let level = dict["level"] as? String,
              let msg = dict["message"] as? String
        else { return }
        if level == "error" {
            logger.error("[JS] \(msg, privacy: .public)")
        } else if level == "warn" {
            logger.warning("[JS] \(msg, privacy: .public)")
        } else {
            logger.info("[JS] \(msg, privacy: .public)")
        }
    }
}

/// Host NSView that contains the active session's WKWebView as its sole
/// subview. Wrapping in a host lets `WebViewContainer.updateNSView` swap
/// the WKWebView in-place when the bound session changes — much faster
/// than tearing down the SwiftUI representable and re-creating it.
final class SessionWebViewHost: NSView {
    override var isFlipped: Bool { true }
}
