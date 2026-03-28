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
