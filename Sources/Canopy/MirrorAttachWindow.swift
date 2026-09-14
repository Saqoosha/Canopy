#if DEBUG
import AppKit
import Network
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

        let bridge = RemoteMirrorBridge(host: host, port: port, sessionId: sessionId, webView: webView)
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

/// TCP client that bridges a WKWebView's vscodeHost messages to a remote MirrorServer.
@MainActor
final class RemoteMirrorBridge: NSObject, WKScriptMessageHandler {
    // Touched from the Network queue in `scheduleReceive`; NWConnection is
    // thread-safe and the line buffer is locked internally.
    nonisolated(unsafe) private let connection: NWConnection
    nonisolated(unsafe) private let lineBuffer = NDJSONLineBuffer()
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorAttach")
    private weak var webView: WKWebView?
    private let sessionId: String
    private var closed = false

    init(host: String, port: UInt16, sessionId: String, webView: WKWebView) {
        self.sessionId = sessionId
        self.webView = webView
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        super.init()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.onReady()
                }
            case .failed(let error):
                logger.error("[mirror-attach] connection failed: \(error.localizedDescription, privacy: .public)")
            case .waiting(let error):
                logger.error("[mirror-attach] waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any] else { return }
        sendJSONObject(dict)
    }

    private func onReady() {
        logger.notice("[mirror-attach] connected")
        sendJSONObject(["type": "attach", "sessionId": sessionId])
        scheduleReceive()
        // Loaded only now, so the webview's `init` cannot reach the socket ahead of `attach`.
        if let webView {
            WebViewContainer.loadCCWebview(webView, resumeSessionId: sessionId, entryFileName: WebViewContainer.entryFileName(for: nil))
        }
    }

    nonisolated private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                logger.error("[mirror-attach] receive error: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let data, !data.isEmpty {
                let lines = self.lineBuffer.append(data)
                DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(self.handleLineData) } }
            }
            if isComplete {
                return
            }
            self.scheduleReceive()
        }
    }

    private func handleLineData(_ data: Data) {
        guard !data.isEmpty else { return }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.error("[mirror-attach] bad JSON: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let dict = object as? [String: Any] else {
            logger.error("[mirror-attach] JSON root is not an object")
            return
        }
        if let type = dict["type"] as? String, type == "attach_error" {
            let message = dict["message"] as? String ?? "attach_error"
            logger.error("[mirror-attach] \(message, privacy: .public)")
            return
        }
        webView?.deliver(dict)
    }

    private func sendJSONObject(_ payload: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("[mirror-attach] send serialize failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { error in
            if let error {
                logger.error("[mirror-attach] send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}

#endif
