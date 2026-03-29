import Cocoa
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "ContentViewer")

/// Shows content in a Monaco editor overlay inside the main webview.
enum ContentViewer {
    /// Show content using Monaco editor overlay in the given webview.
    static func show(content: String, title: String, in webView: WKWebView?) {
        guard let webView else {
            logger.warning("ContentViewer: no webview available")
            return
        }

        // Escape content for JavaScript string literal
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let titleEscaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")

        // Guess language from file name
        let js = """
        (function() {
            // Remove existing overlay if any
            var existing = document.getElementById('hangar-content-viewer');
            if (existing) existing.remove();

            var content = `\(escaped)`;
            var title = `\(titleEscaped)`;

            // Guess language from title
            var lang = 'plaintext';
            var ext = title.split('.').pop().toLowerCase();
            var langMap = {
                'js': 'javascript', 'ts': 'typescript', 'tsx': 'typescript',
                'jsx': 'javascript', 'py': 'python', 'rb': 'ruby',
                'swift': 'swift', 'rs': 'rust', 'go': 'go',
                'json': 'json', 'yaml': 'yaml', 'yml': 'yaml',
                'md': 'markdown', 'html': 'html', 'css': 'css',
                'sh': 'shell', 'bash': 'shell', 'zsh': 'shell',
                'sql': 'sql', 'xml': 'xml', 'toml': 'ini',
                'c': 'c', 'cpp': 'cpp', 'h': 'c', 'hpp': 'cpp',
                'java': 'java', 'kt': 'kotlin',
            };
            if (langMap[ext]) lang = langMap[ext];

            // Create overlay
            var overlay = document.createElement('div');
            overlay.id = 'hangar-content-viewer';
            overlay.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.4);display:flex;align-items:center;justify-content:center;';

            var modal = document.createElement('div');
            modal.style.cssText = 'width:90%;height:85%;background:#fff;border-radius:8px;display:flex;flex-direction:column;box-shadow:0 8px 32px rgba(0,0,0,0.2);';

            // Header
            var header = document.createElement('div');
            header.style.cssText = 'padding:10px 16px;border-bottom:1px solid #e0e0e0;display:flex;align-items:center;justify-content:space-between;flex-shrink:0;';
            var titleEl = document.createElement('span');
            titleEl.textContent = title;
            titleEl.style.cssText = 'font-weight:600;font-size:13px;font-family:-apple-system,sans-serif;';
            var closeBtn = document.createElement('button');
            closeBtn.textContent = '✕';
            closeBtn.style.cssText = 'border:none;background:none;font-size:18px;cursor:pointer;color:#666;padding:0 4px;';
            closeBtn.onclick = function() { overlay.remove(); };
            header.appendChild(titleEl);
            header.appendChild(closeBtn);
            modal.appendChild(header);

            // Editor container
            var editorDiv = document.createElement('div');
            editorDiv.style.cssText = 'flex:1;overflow:hidden;';
            modal.appendChild(editorDiv);
            overlay.appendChild(modal);
            document.body.appendChild(overlay);

            // Close on backdrop click
            overlay.addEventListener('click', function(e) {
                if (e.target === overlay) overlay.remove();
            });

            // Close on Escape
            function onKey(e) {
                if (e.key === 'Escape') { overlay.remove(); document.removeEventListener('keydown', onKey); }
            }
            document.addEventListener('keydown', onKey);

            // Create Monaco editor
            if (globalThis.monaco && globalThis.monaco.editor) {
                globalThis.monaco.editor.create(editorDiv, {
                    value: content,
                    language: lang,
                    theme: 'vs',
                    readOnly: true,
                    minimap: { enabled: false },
                    fontSize: 12,
                    lineNumbers: 'on',
                    scrollBeyondLastLine: false,
                    wordWrap: 'on',
                    automaticLayout: true,
                    renderLineHighlight: 'none',
                    scrollbar: { vertical: 'auto', horizontal: 'auto' },
                });
            } else {
                // Fallback: plain text
                editorDiv.style.cssText += 'padding:16px;overflow:auto;font-family:Menlo,monospace;font-size:12px;white-space:pre-wrap;';
                editorDiv.textContent = content;
            }
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error {
                logger.error("ContentViewer JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
