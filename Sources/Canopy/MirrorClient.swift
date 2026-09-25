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
    /// A `MirrorFileWire` frame: a file the host is shipping here, or a URL to open.
    var onFileFrame: (([String: Any]) -> Void)?
    /// The origin session's account usage (`MirrorUsageFrame`), once it has any and on every
    /// change; never from a Mac that predates the frame.
    var onUsage: (([String: Any]) -> Void)?
    /// The record this bridge's usage lines are filed under, set by the pane from each one; nil
    /// before the first and for this Mac's own account.
    var usageKey: RateLimitAccount.Key?

    /// Every live bridge, for `isWriting(to:)`. Weak, so a closed pane needs no deregistration.
    private static let instances = NSHashTable<RemoteMirrorBridge>.weakObjects()

    /// Whether an attached mirror pane feeds this record — the sidebar's counterpart to
    /// `ShimProcess.isWriting(to:)`, so a remote account's block stays while its pane is attached
    /// and leaves after a drop.
    static func isWriting(to account: RateLimitAccount) -> Bool {
        let registry = SharedRateLimitData.shared
        return instances.allObjects.contains {
            guard let key = $0.usageKey else { return false }
            return registry.canonicalKey(for: key) == account.key
                && $0.attachedDelivered && !$0.terminalDelivered && !$0.closed
        }
    }
    private(set) var extensionVersion: String?
    /// True for a pane whose webview has a `MirrorAssetSchemeHandler`: the attach then asks for Read images as
    /// `canopy-asset` URLs, so the replay does not carry them as base64.
    private let fetchesImages: Bool
    /// `asset_request`s waiting for their `asset_response`, by request id.
    private var pendingAssets: [String: ([String: Any]) -> Void] = [:]

    /// The live bridge driving `webView`, for a message handler that only has the webview.
    static func bridge(for webView: WKWebView?) -> RemoteMirrorBridge? {
        guard let webView else { return nil }
        return instances.allObjects.first { $0.webView === webView }
    }
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

    init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView, fetchesImages: Bool = false) {
        self.fetchesImages = fetchesImages
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
        Self.instances.add(self)
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
        failPendingAssets()
    }

    /// Asks the origin for `path` under its `canopy-asset` root; `completion` gets the `asset_response`, or an
    /// object with only `error` once the connection is gone.
    func requestAsset(path: String, completion: @escaping ([String: Any]) -> Void) {
        guard !closed, !terminalDelivered else {
            completion(["error": "not connected"])
            return
        }
        let id = UUID().uuidString
        pendingAssets[id] = completion
        sendJSONObject(["type": "asset_request", "id": id, "path": path])
    }

    /// The original bytes behind a thumbnail's `canopy-asset://ext/img/<id>` URL, as a data URL for
    /// `ImagePopupWindow`; nil when `url` is not one or the origin cannot serve it.
    func fullImageDataURL(for url: String, completion: @escaping (String?) -> Void) {
        guard let path = Self.fullImagePath(forThumbnailURL: url) else {
            logger.error("[mirror-attach] not a mirror thumbnail URL: \(url.prefix(40), privacy: .public)")
            completion(nil)
            return
        }
        requestAsset(path: path) { reply in
            guard let mime = reply["mime"] as? String, let base64 = reply["base64"] as? String else {
                logger.error("[mirror-attach] full-size image unavailable: \(reply["error"] as? String ?? "no data", privacy: .public)")
                completion(nil)
                return
            }
            completion("data:\(mime);base64,\(base64)")
        }
    }

    /// The `asset_request` path for the original behind a thumbnail's `canopy-asset://ext/img/<id>`.
    nonisolated static func fullImagePath(forThumbnailURL url: String) -> String? {
        let prefix = "\(MirrorConnection.assetScheme)://ext/img/"
        guard url.hasPrefix(prefix), url.count > prefix.count else { return nil }
        return "imgfull/" + url.dropFirst(prefix.count)
    }

    private func failPendingAssets() {
        let pending = pendingAssets
        pendingAssets.removeAll()
        for completion in pending.values { completion(["error": "not connected"]) }
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
            failPendingAssets()
        }
        logger.notice("[mirror-attach] outcome \(String(describing: outcome), privacy: .public); handler set: \(self.onOutcome != nil)")
        onOutcome?(outcome)
    }

    private func onReady() {
        guard !closed else { return }
        logger.notice("[mirror-attach] connected")
        // Token is caller-supplied: a peer's stored password, or this Mac's own for the DEBUG window.
        // `compress`: the transcript replay arrives as one line, and that line is what a slow
        // uplink spends its time on (see `MirrorWire`).
        // `images` (`fetchesImages`): Read images arrive as `canopy-asset` URLs fetched on scroll, not as base64.
        sendJSONObject(["type": "attach", "sessionId": sessionId, "token": token, "client": "mac", "status": true,
                        "compress": MirrorWire.compressionName, "files": true, "usage": true, "images": fetchesImages])
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
        if dict["type"] as? String == "asset_response" {
            // For the scheme handler or the image window that asked, never the page.
            if let id = dict["id"] as? String, let completion = pendingAssets.removeValue(forKey: id) {
                completion(dict)
            }
            return
        }
        if dict["type"] as? String == "usage" {
            // For the sidebar's usage section, not the page.
            onUsage?(dict)
            return
        }
        if MirrorFileWire.isFileFrame(dict["type"] as? String) {
            // For the pane's receiver, never the page: a chunk is a third of
            // a megabyte of base64 the webview has no use for.
            onFileFrame?(dict)
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

/// Serves a mirror pane's `canopy-asset://ext/img/<id>` thumbnails by asking the origin Mac over the bridge,
/// the Mac counterpart of the phone's handler. Only images: the page itself loads from this Mac's extension.
@MainActor
final class MirrorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var bridge: RemoteMirrorBridge?
    /// Tasks WebKit has not stopped. A stopped task must never be answered, or WebKit raises.
    private var live: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url, url.host == "ext", url.path.hasPrefix("/img/"), let bridge else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        live[key] = urlSchemeTask
        bridge.requestAsset(path: String(url.path.dropFirst())) { [weak self] reply in
            // Capturing the task keeps its address from being reused by a later task while this is pending.
            guard let self, let task = self.live[key], task === urlSchemeTask else { return }
            self.live[key] = nil
            guard let mime = reply["mime"] as? String, let base64 = reply["base64"] as? String,
                  let data = Data(base64Encoded: base64)
            else {
                logger.error("[mirror-attach] image \(url.lastPathComponent, privacy: .public) unavailable: \(reply["error"] as? String ?? "no data", privacy: .public)")
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        live[ObjectIdentifier(urlSchemeTask)] = nil
    }
}
