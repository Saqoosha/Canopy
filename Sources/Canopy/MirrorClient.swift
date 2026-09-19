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
    /// The origin's status line, once after `attach_ok` and on every change; never from a Mac older than 2.39.
    var onStatus: (([String: Any]) -> Void)?
    private(set) var extensionVersion: String?
    private var attachedDelivered = false
    private var terminalDelivered = false
    private let token: String

    // Touched from the Network queue in `scheduleReceive`; NWConnection is
    // thread-safe and the line buffer is locked internally.
    nonisolated(unsafe) private let connection: NWConnection
    nonisolated(unsafe) private let lineBuffer = NDJSONLineBuffer(acceptsCompressed: true)
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorAttach")
    private weak var webView: WKWebView?
    private let sessionId: String
    private var closed = false

    init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView) {
        self.token = token
        self.sessionId = sessionId
        self.webView = webView
        // Keepalive, because a server that dies without its FIN reaching us
        // leaves this socket ESTABLISHED forever and no drop is ever reported
        // (measured: studio's server SIGKILLed over Tailscale, the client
        // stayed ESTABLISHED with no error). 15 s idle, 15 s between probes,
        // 3 probes: ~45 s, the budget MacroPad's remote transport and SSH
        // remote use. A dead peer then fails the connection, which is a drop.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 15
        tcp.keepaliveCount = 3
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp)
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
                    guard let self, !self.closed else { return }
                    self.deliverOutcome(.dropped)
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
        logger.notice("[mirror-attach] outcome \(String(describing: outcome), privacy: .public); handler set: \(self.onOutcome != nil)")
        onOutcome?(outcome)
    }

    private func onReady() {
        guard !closed else { return }
        logger.notice("[mirror-attach] connected")
        // Token is caller-supplied: a peer's stored password, or this Mac's own for the DEBUG window.
        // `compress`: a Mac client takes the whole transcript in one line, and that line is
        // what a slow uplink spends its time on (see `MirrorWire`).
        sendJSONObject(["type": "attach", "sessionId": sessionId, "token": token, "client": "mac", "status": true,
                        "compress": MirrorWire.compressionName])
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
                guard let frames = self.lineBuffer.append(data), let lines = NDJSONLineBuffer.lines(from: frames) else {
                    logger.error("[mirror-attach] unreadable frame (over \(NDJSONLineBuffer.maxLineBytes) bytes, or a bad Z header or payload); closing")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !self.closed else { return }
                            self.connection.cancel()
                            self.deliverOutcome(.dropped)
                        }
                    }
                    return
                }
                // In practice the transcript replay; the gap from `attach_ok` is the host's assembly plus transfer.
                for (frame, line) in zip(frames, lines) where line.count >= 1 << 20 {
                    let wire = if case .compressed(let payload, _) = frame { payload.count } else { line.count }
                    logger.notice("[mirror-attach] received a \(line.count, privacy: .public)-byte line (\(wire, privacy: .public) on the wire)")
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(self.handleLineData) } }
            }
            if isComplete {
                logger.notice("[mirror-attach] the server closed the connection")
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
        if dict["type"] as? String == "status" {
            // For the pane's own status bar, not the page.
            onStatus?(dict)
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
