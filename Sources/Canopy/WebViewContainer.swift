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
    var customApi: ModelProvider?
    var connectionState: ConnectionState?
    var onCrash: ((Int32) -> Void)?
    /// The OpenSession that owns this WebView's shim and WKWebView.
    /// Always non-nil in the sidebar shell (every `SessionContainer`
    /// passes one). The type stays Optional because the Coordinator's
    /// reconnect helpers fall back to reading it after the SwiftUI
    /// wrapper has already gone out of scope.
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
        var customApi: ModelProvider?

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

            // Capture the OpenSession from the dying shim BEFORE we drop our
            // reference so we can re-bind ownership onto the replacement.
            // Without this rebinding, `stopOrphanedSessions()` (ownership-
            // based: orphan = no boundSession or boundSession.shim !== self)
            // would target the live reconnected shim at quit time and kill
            // the user's session without confirmation.
            let inheritedSession = shimProcess?.boundSession

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
                remoteHost: remoteHost,
                customApi: customApi
            )
            newShim.delegate = self
            newShim.webView = webView
            ucc.add(newShim, name: "vscodeHost")

            if newShim.start() {
                logger.info("Reconnect succeeded")
                shimProcess = newShim
                if let session = inheritedSession {
                    session.shim = newShim
                    newShim.boundSession = session
                }
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
    func makeNSView(context: Context) -> SessionWebViewHost {
        logger.debug("makeNSView: session=\(self.boundSession?.id.uuidString ?? "nil", privacy: .public) hasShim=\(self.boundSession?.shim != nil) hasWebView=\(self.boundSession?.webView != nil)")
        let host = SessionWebViewHost()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        attachWebView(to: host, coordinator: context.coordinator)
        context.coordinator.lastBoundSessionId = boundSession?.id
        // First-mount focus: same rationale as updateNSView. host.window
        // is nil at this point (SwiftUI hasn't placed the host yet), so
        // defer until the next runloop pass when the window is wired.
        let target = context.coordinator.currentWebView
        DispatchQueue.main.async {
            if let target, let window = target.window {
                window.makeFirstResponder(target)
            }
        }
        return host
    }

    func updateNSView(_ host: SessionWebViewHost, context: Context) {
        // Swap the inner WKWebView when the session bound to this view
        // changes. With `.id(session.id)` on the SessionContainer this
        // guard rarely fires (SwiftUI re-mounts on session change), but
        // we keep it for the SwiftUI double-pass case where makeNSView
        // is followed by an immediate updateNSView with the same id.
        let newId = boundSession?.id
        guard newId != context.coordinator.lastBoundSessionId else {
            // Same session, nothing to swap — but a sibling host built by
            // SwiftUI's second `makeNSView` may have taken the webview since
            // (see `SessionWebViewHost.expectedWebView`). `viewDidMoveToWindow`
            // catches the case where the theft precedes this host being shown;
            // this catches the reverse order, where it was already on screen.
            host.adoptExpectedWebViewIfNeeded()
            return
        }
        logger.debug("updateNSView: swapping \(context.coordinator.lastBoundSessionId?.uuidString ?? "nil", privacy: .public) → \(newId?.uuidString ?? "nil", privacy: .public)")
        host.subviews.forEach { $0.removeFromSuperview() }
        // Reset coordinator state — the previous webView's delegates and
        // handlers were tied to the old session.
        context.coordinator.cancelReconnect()
        context.coordinator.shimProcess = nil
        context.coordinator.consoleHandler = nil
        context.coordinator.linkHandler = nil
        attachWebView(to: host, coordinator: context.coordinator)
        context.coordinator.lastBoundSessionId = newId
        // After a swap (sidebar click into the focused pane, Cmd+Ctrl+1..9
        // Show Session N, or Cmd+Shift+[/] cycle), first-responder ended
        // up somewhere other than the new WKWebView — on the sidebar's
        // List row for the click path, on the menu / window for the
        // keyboard-shortcut paths. The new WKWebView's
        // CSS caret keeps blinking from prior focus state, but AppKit
        // routes keystrokes to whoever is currently first responder
        // (often the window itself), so the user gets a beep until they
        // click into the input field. Hand focus back to the webview.
        let target = context.coordinator.currentWebView
        DispatchQueue.main.async {
            if let target, let window = target.window {
                window.makeFirstResponder(target)
            }
        }
    }

    /// Build (or fetch cached) WKWebView for `boundSession` and add it
    /// as a subview of the host, filling its bounds.
    private func attachWebView(to host: SessionWebViewHost, coordinator: Coordinator) {
        SessionWebViewHost.install(buildWebView(coordinator: coordinator), in: host)
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

        ucc.addUserScript(WKUserScript(
            source: ImagePreviewScript.javascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        ucc.addUserScript(WKUserScript(
            source: InputWidthProbe.javascript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        ucc.addUserScript(WKUserScript(
            source: ScrollPreserveScript.javascript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        ucc.addUserScript(WKUserScript(
            source: RecapScript.javascript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let consoleHandler = ConsoleLogHandler()
        ucc.add(consoleHandler, name: "consoleLog")

        let linkHandler = LinkClickHandler(workingDirectory: workingDirectory)
        ucc.add(linkHandler, name: "canopyLink")

        // Handler init takes a non-optional StatusBarData so callers with
        // nothing to write into just skip registration entirely (compile-
        // time enforcement of "no data → no handler"). Nothing else in
        // buildWebView constructs one without also having statusBarData
        // set, but keep the guard so a future refactor can't slip past.
        let inputWidthHandler = statusBarData.map { InputWidthMessageHandler(statusBarData: $0) }
        if let inputWidthHandler {
            ucc.add(inputWidthHandler, name: InputWidthProbe.messageHandlerName)
        }

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
                remoteHost: remoteHost,
                customApi: customApi
            )
            isFreshShim = true
            // Bind the shim to the OpenSession IMMEDIATELY, before the
            // expensive `shim.start()` call below. Otherwise a second
            // `makeNSView` triggered while the Node subprocess is spawning
            // (~150 ms) sees `boundSession.shim == nil`, allocates and
            // starts a *second* shim, and orphans the first — which then
            // keeps `process?.isRunning == true` forever and trips
            // `hasActiveSession` even after the user closed the session.
            if let session = boundSession {
                session.shim = shim
                shim.boundSession = session
            }
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
        coordinator.customApi = customApi
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
            cachedUcc.removeScriptMessageHandler(forName: InputWidthProbe.messageHandlerName)
            cachedUcc.add(consoleHandler, name: "consoleLog")
            cachedUcc.add(linkHandler, name: "canopyLink")
            cachedUcc.add(shim, name: "vscodeHost")
            if let inputWidthHandler {
                cachedUcc.add(inputWidthHandler, name: InputWidthProbe.messageHandlerName)
            }
        } else {
            webView = WKWebView(frame: .zero, configuration: config)
            webView.isInspectable = true
            isFreshWebView = true
            // Early-bind to the OpenSession before the (slow) loadCCWebview
            // call. Without this, a concurrent `makeNSView` triggered while
            // we're still inside this call sees `boundSession?.webView == nil`,
            // allocates a *second* WebView, and the first one ends up
            // orphaned — loaded but never attached to the user's view
            // hierarchy. Pairs with the early shim bind above.
            boundSession?.webView = webView
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        shim.webView = webView
        coordinator.currentWebView = webView
        logger.debug("buildWebView: isFreshShim=\(isFreshShim) isFreshWebView=\(isFreshWebView) shim=\(ObjectIdentifier(shim).hashValue) webView=\(ObjectIdentifier(webView).hashValue)")
        if isFreshShim {
            if !shim.start() {
                logger.error("Shim start failed — no fallback available")
                // Session was early-bound to this shim above. With the shim
                // dead, the OpenSession would otherwise stay in `.spawning`
                // forever (no termination handler fires). Route through the
                // crash path so SessionContainer flips to `.crashed` and
                // surfaces an error UI.
                coordinator.onCrash?(-1)
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
    static func dismantleNSView(_ host: SessionWebViewHost, coordinator: Coordinator) {
        coordinator.cancelReconnect()
        for sub in host.subviews {
            if let wk = sub as? WKWebView {
                wk.navigationDelegate = nil
                wk.uiDelegate = nil
                let ucc = wk.configuration.userContentController
                ucc.removeScriptMessageHandler(forName: "vscodeHost")
                ucc.removeScriptMessageHandler(forName: "consoleLog")
                ucc.removeScriptMessageHandler(forName: "canopyLink")
                ucc.removeScriptMessageHandler(forName: InputWidthProbe.messageHandlerName)
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
        // One entry file PER SESSION, never a shared `_canopy.html`.
        //
        // `data-initial-session` — the only thing that tells the CC extension's
        // webview which conversation to render — is baked into this HTML, and
        // `loadFileURL` reads the file asynchronously. Two webviews built in the
        // same runloop tick therefore raced on one shared path: the second
        // session's HTML overwrote the first's before the first had read it, and
        // the loser rendered an empty conversation with no error anywhere.
        // Opening panes by hand never hit it (the writes are seconds apart);
        // restoring a pane strip at launch hit it every single time.
        //
        // The file must OUTLIVE the load, not be deleted after it:
        // `webViewWebContentProcessDidTerminate` recovers by calling
        // `webView.reload()`, which re-reads this exact URL.
        let htmlFile = appSupportDir.appendingPathComponent(Self.entryFileName(for: boundSession))
        do {
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write \(htmlFile.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            webView.loadHTMLString(
                "<html><body style='background:#fff;color:#333;padding:40px;font-family:sans-serif'>"
                + "<h1>Canopy Error</h1><p>Failed to write webview HTML: \(error.localizedDescription)</p></body></html>",
                baseURL: nil
            )
            return
        }
        Self.noteEntryFileWritten(htmlFile)
        // Allow read access to home directory (covers Application Support HTML and extension resources)
        let commonParent = FileManager.default.homeDirectoryForCurrentUser
        webView.loadFileURL(htmlFile, allowingReadAccessTo: commonParent)
    }

    // MARK: - Webview entry files

    static let entryFilePrefix = "_canopy-"

    /// Per-session name for the webview's HTML entry point. Keyed by the
    /// `OpenSession`'s process-local UUID rather than its resumeId, because
    /// `ShimProcess.backfillResumeId` rewrites the resumeId mid-session and the
    /// file this webview is loaded from must not move under it.
    private static func entryFileName(for session: OpenSession?) -> String {
        guard let session else { return "\(entryFilePrefix)default.html" }
        return "\(entryFilePrefix)\(session.id.uuidString).html"
    }

    /// Entry files THIS process has written. The only thing `purgeOwnEntryFiles`
    /// is allowed to delete.
    @MainActor private static var ownedEntryFiles: Set<URL> = []

    @MainActor static func noteEntryFileWritten(_ url: URL) {
        ownedEntryFiles.insert(url)
    }

    /// Delete the entry files this process wrote. Call this **at quit only**,
    /// and note the two separate reasons it is scoped this narrowly.
    ///
    /// *Quit, not launch:* `applicationDidFinishLaunching` runs **after**
    /// SwiftUI's first render — measured, and the opposite of the obvious guess.
    /// With a restored pane strip the shims are already up and the webviews have
    /// already written their HTML, so a launch-time sweep deletes files that are
    /// mid-load and every pane renders blank white.
    ///
    /// *Own files, not the whole directory:* `~/Library/Application Support/Canopy`
    /// is named after the app, not the bundle id, so a Debug build
    /// (`sh.saqoo.Canopy.debug`) and the installed Release share it. A sweep by
    /// glob therefore deletes the OTHER instance's live entry files — and since
    /// `webViewWebContentProcessDidTerminate` recovers by re-reading that exact
    /// URL, the damage lands much later and nowhere near the cause.
    ///
    /// Cost of the narrow scope: a crashed run leaves its files behind for good,
    /// since nothing else will ever claim them. They are inert and small, and a
    /// heuristic sweep by age would re-open the cross-instance hazard on any
    /// session that outlives the cutoff.
    @MainActor static func purgeOwnEntryFiles() {
        let owned = ownedEntryFiles
        ownedEntryFiles.removeAll()
        for url in owned {
            try? FileManager.default.removeItem(at: url)
        }
        if !owned.isEmpty {
            logger.info("Purged \(owned.count) webview entry file(s) written by this process")
        }
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

    /// The WKWebView this host is supposed to be showing.
    ///
    /// SwiftUI calls `makeNSView` **twice** for one `SessionContainer` (the
    /// reason is already documented on `buildWebView`'s shim-reuse guard) and
    /// then keeps EITHER host. The WKWebView is cached on the `OpenSession`,
    /// and `addSubview` **re-parents**, so the second `makeNSView` pulls the
    /// webview out of the first host. If SwiftUI then keeps the first, the
    /// host it puts on screen has no subviews at all and the pane renders as
    /// a blank white rectangle — with the shim, the CLI and the page load all
    /// perfectly healthy, which is what makes it so hard to read from logs.
    ///
    /// Which host survives is not ours to choose, so the host asserts the
    /// invariant itself: *whoever is on screen holds the webview*. Restoring
    /// a pane strip at launch takes the losing ordering every time; opening a
    /// session by hand happened to take the other one, which is why this sat
    /// latent until launch restore shipped.
    weak var expectedWebView: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adoptExpectedWebViewIfNeeded()
    }

    /// Re-parent `expectedWebView` back under this host when this host is the
    /// one on screen. A no-op in the overwhelmingly common case where the
    /// webview never moved.
    func adoptExpectedWebViewIfNeeded() {
        guard window != nil,
              let expectedWebView,
              expectedWebView.superview !== self
        else { return }
        Self.install(expectedWebView, in: self)
    }

    /// Pin `webView` to every edge of `host`. Fresh constraints each time:
    /// the previous set crossed the old host boundary and `removeFromSuperview`
    /// already tore it down.
    static func install(_ webView: NSView, in host: SessionWebViewHost) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        host.expectedWebView = webView
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}
