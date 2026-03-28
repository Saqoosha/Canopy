import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "WebView")

struct WebViewContainer: NSViewRepresentable {
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("Page loaded successfully")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[Hangar] Navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[Hangar] Provisional navigation failed: \(error)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()

        // 1. Capture JS console output
        ucc.addUserScript(WKUserScript(
            source: Self.consoleCapture,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // 2. Inject acquireVsCodeApi stub + globals
        ucc.addUserScript(WKUserScript(
            source: VSCodeStub.javascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let handler = WebViewMessageHandler()
        ucc.add(handler, name: "vscodeHost")
        ucc.add(ConsoleLogHandler(), name: "consoleLog")

        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(true, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true

        handler.webView = webView
        loadCCWebview(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - Load CC webview

    private func loadCCWebview(_ webView: WKWebView) {
        guard let extPath = Self.findCCExtensionPath() else {
            webView.loadHTMLString(
                "<html><body style='background:#ffffff;color:#333;padding:40px;font-family:sans-serif'>"
                + "<h1>Hangar</h1><p>Claude Code extension not found</p></body></html>",
                baseURL: nil
            )
            return
        }

        let webviewDir = extPath.appendingPathComponent("webview")
        let cssFile = webviewDir.appendingPathComponent("index.css")
        let jsFile = webviewDir.appendingPathComponent("index.js")

        print("[Hangar] Extension path: \(extPath.path)")
        print("[Hangar] CSS exists: \(FileManager.default.fileExists(atPath: cssFile.path))")
        print("[Hangar] JS exists: \(FileManager.default.fileExists(atPath: jsFile.path))")

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>\(VSCodeStub.themeCSSVariables)</style>
          <link href="index.css" rel="stylesheet">
          <style>
            :root {
              --vscode-editor-font-family: "SF Mono", Menlo, Monaco, monospace !important;
              --vscode-editor-font-size: 13px !important;
              --vscode-editor-font-weight: normal !important;
              --vscode-chat-font-size: 13px;
              --vscode-chat-font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              /* Variables injected by VSCode host, not defined in CC extension CSS */
              --app-code-background: var(--vscode-textCodeBlock-background);
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
        </head>
        <body class="vscode-light">
          <pre id="claude-error"></pre>
          <div id="root"></div>
          <script src="index.js" type="module"></script>
        </body>
        </html>
        """

        // Use loadFileURL to allow local file access properly
        let htmlFile = webviewDir.appendingPathComponent("_hangar.html")
        try? html.write(to: htmlFile, atomically: true, encoding: .utf8)
        webView.loadFileURL(htmlFile, allowingReadAccessTo: extPath)
    }

    static func findCCExtensionPath() -> URL? {
        let extensionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: extensionsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("anthropic.claude-code-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

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
            } catch(e) {}
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
