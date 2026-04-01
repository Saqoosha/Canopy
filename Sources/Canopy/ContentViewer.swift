import Cocoa
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ContentViewer")

/// Shows content in a Monaco editor overlay inside the main webview.
enum ContentViewer {
    /// Show content using Monaco editor overlay in the given webview.
    /// - Parameters:
    ///   - startLine: 1-based start line to reveal and highlight (optional)
    ///   - endLine: 1-based end line of highlight range (optional, defaults to startLine)
    static func show(
        content: String, title: String, in webView: WKWebView?,
        startLine: Int? = nil, endLine: Int? = nil
    ) {
        guard let webView else {
            logger.warning("ContentViewer: no webview available")
            return
        }

        // Safely encode content and title as JSON strings to prevent JS injection.
        // JSONEncoder handles String directly; NSJSONSerialization only accepts Array/Dictionary
        // and throws an uncatchable ObjC exception on bare strings.
        guard let contentData = try? JSONEncoder().encode(content),
              let contentJSON = String(data: contentData, encoding: .utf8),
              let titleData = try? JSONEncoder().encode(title),
              let titleJSON = String(data: titleData, encoding: .utf8)
        else {
            logger.error("ContentViewer: failed to encode content as JSON")
            return
        }

        let startLineJS = startLine.map(String.init) ?? "null"
        let endLineJS = endLine.map(String.init) ?? startLineJS

        let js = """
        (function() {
            // Remove existing overlay if any
            var existing = document.getElementById('canopy-content-viewer');
            if (existing) existing.remove();

            var content = \(contentJSON);
            var title = \(titleJSON);
            var startLine = \(startLineJS);
            var endLine = \(endLineJS);

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

            // Create overlay — matches CC extension's diff modal (modalBackdrop/modalContent_oXZawA)
            var overlay = document.createElement('div');
            overlay.id = 'canopy-content-viewer';
            overlay.style.cssText = 'position:fixed;inset:0;z-index:1000;background-color:var(--app-primary-background, rgba(0,0,0,0.4));display:flex;justify-content:center;align-items:center;padding:16px;';

            var modal = document.createElement('div');
            modal.style.cssText = 'background-color:var(--app-primary-background, #fff);display:flex;overflow:hidden;border:1px solid var(--app-input-border, #e0e0e0);border-radius:4px;flex-direction:column;width:calc(100vw - 40px);max-width:1400px;height:calc(100vh - 40px);max-height:900px;box-shadow:0 4px 12px rgba(0,0,0,0.05);';

            // Header — matches CC extension's modalHeader_oXZawA
            var header = document.createElement('div');
            header.style.cssText = 'display:flex;border-bottom:1px solid var(--app-input-border, #e0e0e0);background-color:var(--app-secondary-background, #f5f5f5);align-items:center;gap:12px;padding:8px 12px;flex-shrink:0;';
            var titleEl = document.createElement('span');
            titleEl.textContent = title;
            titleEl.style.cssText = 'color:var(--app-primary-foreground, #333);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;min-width:0;font-weight:600;';
            var closeBtn = document.createElement('button');
            closeBtn.textContent = '✕';
            closeBtn.style.cssText = 'border:none;background:none;font-size:16px;cursor:pointer;color:var(--app-secondary-foreground, #666);padding:0 4px;';
            closeBtn.onclick = function() { closeViewer(); };
            header.appendChild(titleEl);
            header.appendChild(closeBtn);
            modal.appendChild(header);

            // Editor container
            var editorDiv = document.createElement('div');
            editorDiv.style.cssText = 'flex:1;overflow:hidden;';
            modal.appendChild(editorDiv);
            overlay.appendChild(modal);
            document.body.appendChild(overlay);

            var editorInstance = null;
            var decorations = [];
            function closeViewer() {
                if (editorInstance) { editorInstance.dispose(); editorInstance = null; }
                overlay.remove();
                document.removeEventListener('keydown', onKey);
            }

            // Close on backdrop click
            overlay.addEventListener('click', function(e) {
                if (e.target === overlay) closeViewer();
            });

            // Close on Escape
            function onKey(e) {
                if (e.key === 'Escape') closeViewer();
            }
            document.addEventListener('keydown', onKey);

            // Create Monaco editor
            if (globalThis.monaco && globalThis.monaco.editor) {
                editorInstance = globalThis.monaco.editor.create(editorDiv, {
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

                // Jump to line and highlight range
                if (startLine !== null) {
                    var sl = startLine;
                    var el = endLine !== null ? endLine : sl;
                    editorInstance.revealLineInCenter(sl);
                    editorInstance.setSelection(new globalThis.monaco.Selection(sl, 1, el + 1, 1));
                    decorations = editorInstance.deltaDecorations([], [{
                        range: new globalThis.monaco.Range(sl, 1, el, 1000),
                        options: {
                            isWholeLine: true,
                            className: 'canopy-line-highlight',
                            overviewRuler: { color: 'rgba(255, 213, 79, 0.8)', position: 1 }
                        }
                    }]);
                }
            } else {
                // Fallback: plain text
                editorDiv.style.cssText += 'padding:16px;overflow:auto;font-family:Menlo,monospace;font-size:12px;white-space:pre-wrap;';
                editorDiv.textContent = content;
            }

            // Inject highlight style if not present
            if (!document.getElementById('canopy-cv-style')) {
                var style = document.createElement('style');
                style.id = 'canopy-cv-style';
                style.textContent = '.canopy-line-highlight { background: rgba(255, 213, 79, 0.3) !important; }';
                document.head.appendChild(style);
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
