import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "WebView")

struct WebViewContainer: NSViewRepresentable {
    let workingDirectory: URL
    var resumeSessionId: String?
    var permissionMode: PermissionMode = .acceptEdits
    var sessionTitle: String?
    var statusBarData: StatusBarData?
    var remoteHost: String?

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var shimProcess: ShimProcess?
        var consoleHandler: ConsoleLogHandler?
        var linkHandler: LinkClickHandler?

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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
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

        let shim = ShimProcess(
            workingDirectory: workingDirectory,
            resumeSessionId: resumeSessionId,
            permissionMode: permissionMode,
            sessionTitle: sessionTitle,
            statusBarData: statusBarData,
            remoteHost: remoteHost
        )
        ucc.add(shim, name: "vscodeHost")
        context.coordinator.shimProcess = shim
        context.coordinator.consoleHandler = consoleHandler
        context.coordinator.linkHandler = linkHandler

        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = true

        context.coordinator.shimProcess?.webView = webView
        if context.coordinator.shimProcess?.start() != true {
            logger.error("Shim start failed — no fallback available")
        }
        loadCCWebview(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Clean up WKScriptMessageHandler references to prevent memory leak.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        let ucc = nsView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "vscodeHost")
        ucc.removeScriptMessageHandler(forName: "consoleLog")
        ucc.removeScriptMessageHandler(forName: "canopyLink")
        ucc.removeAllUserScripts()
        coordinator.shimProcess?.stop()
        coordinator.shimProcess = nil
        coordinator.consoleHandler = nil
        coordinator.linkHandler = nil
        logger.info("WebView dismantled, handlers removed")
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

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>\(VSCodeStub.themeCSSVariables)</style>
          <link href="\(cssFile.absoluteString)" rel="stylesheet">
          <style>
            :root {
              --vscode-editor-font-family: "SF Mono", Menlo, Monaco, monospace !important;
              --vscode-editor-font-size: 13px !important;
              --vscode-editor-font-weight: normal !important;
              --vscode-chat-font-size: 13px;
              --vscode-chat-font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              /* Variables injected by VSCode host, not defined in CC extension CSS */
              --app-code-background: var(--vscode-editor-background);
              --app-link-color: var(--vscode-textLink-foreground);
              --app-link-foreground: var(--vscode-textLink-foreground);
              --app-link: var(--vscode-textLink-foreground);
              --app-font-family-mono: var(--vscode-editor-font-family, monospace);
              --app-background: var(--vscode-editor-background);
              --app-root-background: var(--vscode-sideBar-background);
              --app-secondary-text: var(--vscode-descriptionForeground);
              --app-text-secondary: var(--vscode-descriptionForeground);
            }
          </style>
          <!-- Timeline line fix: each timelineMessage is also a .message (position:relative),
               so ::after lines are scoped per-element. Extend bottom to bridge the 15px gap to next dot. -->
          <style>
            [class*="message_"][class*="timelineMessage_"]::after {
              bottom: -15px !important;
            }
          </style>
          <!-- VSCode webview default styles (from VSCode's webview/browser/pre/index.html) -->
          <style>
            @layer vscode-default {
              html {
                scrollbar-color: var(--vscode-scrollbarSlider-background) var(--vscode-editor-background);
              }
              body {
                overscroll-behavior-x: none;
                background-color: transparent;
                color: var(--vscode-editor-foreground);
                font-family: var(--vscode-font-family, -apple-system, BlinkMacSystemFont, sans-serif);
                font-weight: var(--vscode-font-weight, normal);
                font-size: var(--vscode-font-size, 13px);
                margin: 0;
                padding: 0;
              }
              img, video { max-width: 100%; max-height: 100%; }
              a, a code { color: var(--vscode-textLink-foreground); }
              a:hover { color: var(--vscode-textLink-activeForeground); }
              a:focus, input:focus, select:focus, textarea:focus {
                outline: 1px solid -webkit-focus-ring-color;
                outline-offset: -1px;
              }
              code {
                font-family: var(--vscode-editor-font-family, monospace);
                color: var(--vscode-textPreformat-foreground);
                background-color: var(--vscode-textPreformat-background);
                padding: 1px 3px;
                border-radius: 4px;
              }
              pre code { padding: 0; }
              blockquote {
                background: var(--vscode-textBlockQuote-background);
                border-color: var(--vscode-textBlockQuote-border);
              }
              kbd {
                background-color: var(--vscode-keybindingLabel-background);
                color: var(--vscode-keybindingLabel-foreground);
                border-style: solid; border-width: 1px; border-radius: 3px;
                border-color: var(--vscode-keybindingLabel-border);
                border-bottom-color: var(--vscode-keybindingLabel-bottomBorder);
                box-shadow: inset 0 -1px 0 var(--vscode-widget-shadow);
                vertical-align: middle; padding: 1px 3px;
              }
              ::-webkit-scrollbar { width: 10px; height: 10px; }
              ::-webkit-scrollbar-corner { background-color: var(--vscode-editor-background); }
              ::-webkit-scrollbar-thumb { background-color: var(--vscode-scrollbarSlider-background); }
              ::-webkit-scrollbar-thumb:hover { background-color: var(--vscode-scrollbarSlider-hoverBackground); }
              ::-webkit-scrollbar-thumb:active { background-color: var(--vscode-scrollbarSlider-activeBackground); }
            }
          </style>
          <style>
            /* Fix br not rendering in contenteditable input fields in WKWebView */
            [contenteditable] {
              white-space: pre-wrap !important;
              word-wrap: break-word !important;
            }
            /* Tool name secondary text: use description color instead of link color */
            [class*="toolNameTextSecondary_"] {
              color: var(--app-secondary-foreground) !important;
            }
            /* Fix diff truncation gradient: hardcoded dark #1e1e1e → light */
            [class*="truncationGradient_"] {
              background: linear-gradient(transparent 0%, var(--vscode-editor-background, #ffffff) 100%) !important;
            }
          </style>
        </head>
        <body class="vscode-light">
          <pre id="claude-error"></pre>
          <div id="root"\(resumeSessionId.map { " data-initial-session=\"\($0)\"" } ?? "")\(Self.initialAuthStatusAttr())></div>
          <script src="\(jsFile.absoluteString)" type="module"></script>
        </body>
        </html>
        """

        // Write HTML to Application Support (under home dir so allowingReadAccessTo works)
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
        // Allow read access to both temp dir (for HTML) and extension dir (for JS/CSS/resources)
        let commonParent = FileManager.default.homeDirectoryForCurrentUser
        webView.loadFileURL(htmlFile, allowingReadAccessTo: commonParent)
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
