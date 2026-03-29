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

    // Fix Monaco diff editor: CC extension hardcodes theme:"vs-dark" in createDiffEditor.
    // Monaco only exports to globalThis.monaco when MonacoEnvironment.globalAPI is true.
    // We set that flag, then redefine "vs-dark" as a light theme.
    globalThis.MonacoEnvironment = Object.assign(globalThis.MonacoEnvironment || {}, {
        globalAPI: true
    });
    (function() {
        var patched = false;
        function patchMonaco() {
            if (patched) return;
            var m = globalThis.monaco;
            if (!m || !m.editor || !m.editor.defineTheme) return;
            patched = true;
            m.editor.defineTheme('vs-dark', {
                base: 'vs',
                inherit: true,
                rules: [],
                colors: {}
            });
            console.log('[Hangar] Redefined vs-dark as light theme');
        }
        var poll = setInterval(function() {
            if (globalThis.monaco && globalThis.monaco.editor) {
                patchMonaco();
                clearInterval(poll);
            }
        }, 50);
        setTimeout(function() { clearInterval(poll); }, 30000);
    })();

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
