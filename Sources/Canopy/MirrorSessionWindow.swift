#if DEBUG
import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorSessionWindow")

@MainActor
final class MirrorSessionWindow: NSObject, NSWindowDelegate {
    private static var openWindows: [MirrorSessionWindow] = []

    private let window: NSWindow
    private let webView: WKWebView
    private weak var shim: ShimProcess?
    private let consoleHandler: ConsoleLogHandler
    private let linkHandler: LinkClickHandler

    static func open(for session: OpenSession) {
        guard let shim = session.shim else {
            logger.warning("mirror: session has no shim")
            return
        }

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        // Same as `WebViewContainer.buildWebView`; without it the page renders blank.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        WebViewContainer.addSessionUserScripts(to: ucc)

        let consoleHandler = ConsoleLogHandler()
        ucc.add(consoleHandler, name: "consoleLog")

        let linkHandler = LinkClickHandler(workingDirectory: session.origin.workingDirectory)
        ucc.add(linkHandler, name: "canopyLink")

        ucc.add(shim, name: "vscodeHost")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true

        shim.attachMirror(webView)

        WebViewContainer.loadCCWebview(
            webView,
            resumeSessionId: session.resumeId,
            entryFileName: WebViewContainer.entryFileName(for: nil)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mirror — \(session.title)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()

        let instance = MirrorSessionWindow(
            window: window,
            webView: webView,
            shim: shim,
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
        logger.notice("mirror: opened for session \(session.resumeId, privacy: .public)")
    }

    private init(
        window: NSWindow,
        webView: WKWebView,
        shim: ShimProcess,
        consoleHandler: ConsoleLogHandler,
        linkHandler: LinkClickHandler
    ) {
        self.window = window
        self.webView = webView
        self.shim = shim
        self.consoleHandler = consoleHandler
        self.linkHandler = linkHandler
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        shim?.detachMirror(webView)
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "consoleLog")
        ucc.removeScriptMessageHandler(forName: "canopyLink")
        ucc.removeScriptMessageHandler(forName: "vscodeHost")
        Self.openWindows.removeAll { $0 === self }
        logger.notice("mirror: closed")
    }
}
#endif
