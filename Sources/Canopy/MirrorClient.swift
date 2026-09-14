import AppKit
import Network
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorAttach")

/// TCP client that bridges a WKWebView's vscodeHost messages to a remote MirrorServer.
@MainActor
final class RemoteMirrorBridge: NSObject, WKScriptMessageHandler {
    enum Outcome: Equatable { case attached, refused(String), dropped }

    var onOutcome: ((Outcome) -> Void)?
    private(set) var extensionVersion: String?
    private var attachedDelivered = false
    private var terminalDelivered = false
    private let token: String

    // Touched from the Network queue in `scheduleReceive`; NWConnection is
    // thread-safe and the line buffer is locked internally.
    nonisolated(unsafe) private let connection: NWConnection
    nonisolated(unsafe) private let lineBuffer = NDJSONLineBuffer()
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorAttach")
    private weak var webView: WKWebView?
    private let sessionId: String
    private var closed = false

    init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView) {
        self.token = token
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
                Task { @MainActor in
                    self?.deliverOutcome(.dropped)
                }
            case .waiting(let error):
                logger.error("[mirror-attach] waiting: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    guard let self, !self.attachedDelivered, !self.closed else { return }
                    self.connection.cancel()
                    self.deliverOutcome(.dropped)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.attachedDelivered, !self.closed else { return }
                logger.error("[mirror-attach] no attach_ok within 15 s; giving up")
                self.connection.cancel()
                self.deliverOutcome(.dropped)
            }
        }
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

    /// `.attached` is delivered at most once; one terminal outcome (`.refused` or `.dropped`) is delivered at most once, after which nothing more is.
    private func deliverOutcome(_ outcome: Outcome) {
        if terminalDelivered { return }
        switch outcome {
        case .attached:
            guard !attachedDelivered else { return }
            attachedDelivered = true
        case .refused, .dropped:
            terminalDelivered = true
        }
        onOutcome?(outcome)
    }

    private func onReady() {
        logger.notice("[mirror-attach] connected")
        // Token is caller-supplied (DEBUG window: this Mac's MirrorAccess).
        sendJSONObject(["type": "attach", "sessionId": sessionId, "token": token, "client": "mac"])
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
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !self.closed else { return }
                        self.deliverOutcome(.dropped)
                    }
                }
                return
            }
            if let data, !data.isEmpty {
                guard let lines = self.lineBuffer.append(data) else {
                    logger.error("[mirror-attach] line over \(NDJSONLineBuffer.maxLineBytes) bytes; closing")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !self.closed else { return }
                            self.connection.cancel()
                            self.deliverOutcome(.dropped)
                        }
                    }
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(self.handleLineData) } }
            }
            if isComplete {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !self.closed else { return }
                        self.deliverOutcome(.dropped)
                    }
                }
                return
            }
            self.scheduleReceive()
        }
    }

    private func handleLineData(_ data: Data) {
        guard !data.isEmpty, !closed else { return }
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
        if dict["type"] as? String == "attach_ok" {
            logger.notice("[mirror-attach] attach_ok")
            extensionVersion = dict["extensionVersion"] as? String
            deliverOutcome(.attached)
            return
        }
        if let type = dict["type"] as? String, type == "attach_error" {
            let message = dict["message"] as? String ?? "attach_error"
            logger.error("[mirror-attach] \(message, privacy: .public)")
            deliverOutcome(.refused(message))
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
