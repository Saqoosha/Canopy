import Cocoa
import WebKit

/// Opens content in a new lightweight window with syntax-highlighted text.
enum ContentViewer {
    static func show(content: String, title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false

        let webView = WKWebView(frame: window.contentLayoutRect)
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView

        let escaped = content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body {
            margin: 0;
            padding: 16px;
            background: #f8f9fa;
            color: #1e1e1e;
            font-family: Menlo, Monaco, 'Courier New', monospace;
            font-size: 12px;
            line-height: 1.5;
            -webkit-user-select: text;
          }
          pre {
            margin: 0;
            white-space: pre-wrap;
            word-wrap: break-word;
          }
        </style>
        </head>
        <body><pre>\(escaped)</pre></body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
    }
}
