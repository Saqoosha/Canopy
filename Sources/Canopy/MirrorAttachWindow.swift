#if DEBUG
import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorAttach")

/// Debug window that attaches a local WKWebView to a remote Canopy's MirrorServer.
@MainActor
final class MirrorAttachWindow: NSObject, NSWindowDelegate {
    private static var openWindows: [MirrorAttachWindow] = []

    private let window: NSWindow
    private let webView: WKWebView
    private let bridge: RemoteMirrorBridge
    private let consoleHandler: ConsoleLogHandler
    private let linkHandler: LinkClickHandler

    static func promptAndOpen() {
        let alert = NSAlert()
        alert.messageText = "Attach to Remote Session"
        alert.informativeText = "host:port/sessionId"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "127.0.0.1:8770/"
        alert.accessoryView = field
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = text.firstIndex(of: "/") else {
            logger.error("[mirror-attach] expected host:port/sessionId")
            return
        }
        let sessionId = String(text[text.index(after: slash)...])
        let hostPort = String(text[..<slash])
        guard !sessionId.isEmpty,
              let colon = hostPort.lastIndex(of: ":") else {
            logger.error("[mirror-attach] expected host:port/sessionId")
            return
        }
        let host = String(hostPort[..<colon])
        let portText = String(hostPort[hostPort.index(after: colon)...])
        guard !host.isEmpty, let port = UInt16(portText) else {
            logger.error("[mirror-attach] invalid port")
            return
        }
        open(host: host, port: port, sessionId: sessionId)
    }

    static func open(host: String, port: UInt16, sessionId: String) {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        // Same as `WebViewContainer.buildWebView`; without it the page renders blank.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        WebViewContainer.addSessionUserScripts(to: ucc)

        let consoleHandler = ConsoleLogHandler()
        ucc.add(consoleHandler, name: "consoleLog")

        let linkHandler = LinkClickHandler(workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
        ucc.add(linkHandler, name: "canopyLink")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true

        // Same-Mac test window; token comes from this machine's MirrorAccess.
        let bridge = RemoteMirrorBridge(
            host: host,
            port: port,
            sessionId: sessionId,
            token: MirrorAccess.token(createIfMissing: true) ?? "",
            webView: webView
        )
        ucc.add(bridge, name: "vscodeHost")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Attach — \(host):\(port)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()

        let instance = MirrorAttachWindow(
            window: window,
            webView: webView,
            bridge: bridge,
            consoleHandler: consoleHandler,
            linkHandler: linkHandler
        )
        window.delegate = instance

        var origin = window.frame.origin
        origin.x += CGFloat(40 * openWindows.count)
        origin.y -= CGFloat(40 * openWindows.count)
        window.setFrameOrigin(origin)

        window.makeKeyAndOrderFront(nil)
        openWindows.append(instance)
        logger.notice("[mirror-attach] opened \(host, privacy: .public):\(port)/\(sessionId, privacy: .public)")
    }

    private init(
        window: NSWindow,
        webView: WKWebView,
        bridge: RemoteMirrorBridge,
        consoleHandler: ConsoleLogHandler,
        linkHandler: LinkClickHandler
    ) {
        self.window = window
        self.webView = webView
        self.bridge = bridge
        self.consoleHandler = consoleHandler
        self.linkHandler = linkHandler
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        bridge.close()
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "consoleLog")
        ucc.removeScriptMessageHandler(forName: "canopyLink")
        ucc.removeScriptMessageHandler(forName: "vscodeHost")
        Self.openWindows.removeAll { $0 === self }
        logger.notice("[mirror-attach] closed")
    }
}

#endif
