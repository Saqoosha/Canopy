import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "VSCodeStub")

enum VSCodeStub {
    /// JavaScript stub injected before the webview loads.
    /// Replaces acquireVsCodeApi() and sets up the postMessage bridge to Swift.
    static let javascript = """
    // VSCode API stub for Hangar
    window.IS_SIDEBAR = false;
    window.IS_FULL_EDITOR = true;
    window.IS_SESSION_LIST_ONLY = false;

    window.acquireVsCodeApi = function() {
        return {
            postMessage: function(msg) {
                window.webkit.messageHandlers.vscodeHost.postMessage(msg);
            },
            getState: function() { return null; },
            setState: function(state) { return state; }
        };
    };

    // Fix Japanese IME: WebKit Bug 165004 — compositionend fires BEFORE keydown,
    // so isComposing is always false for the IME-confirming Enter. The only reliable
    // signal is keyCode === 229 (VK_PROCESS), which WebKit sets for all IME keydowns.
    // We patch isComposing to true when keyCode is 229, so the CC extension's
    // `if (e.nativeEvent.isComposing) return` check works correctly.
    (function() {
        document.addEventListener('keydown', function(e) {
            if (e.keyCode === 229 && !e.isComposing) {
                Object.defineProperty(e, 'isComposing', { get: function() { return true; } });
            }
        }, true);
    })();
    """

    /// Load theme CSS from bundled resource file.
    /// Generated from VSCode's "Developer: Generate Color Theme From Current Settings"
    /// with Default Light+ theme active.
    static var themeCSSVariables: String {
        guard let url = Bundle.main.url(forResource: "theme-light", withExtension: "css") else {
            logger.error("theme-light.css not found in bundle")
            return ":root { --vscode-editor-background: #ffffff; --vscode-editor-foreground: #000000; }"
        }
        guard let css = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Failed to read theme-light.css")
            return ":root { --vscode-editor-background: #ffffff; --vscode-editor-foreground: #000000; }"
        }
        return css
    }
}
