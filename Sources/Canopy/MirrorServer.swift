import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorServer")

/// What the Settings tab shows about the live-mirror listener.
@Observable
@MainActor
final class MirrorServerStatus {
    enum State: Equatable {
        case off
        case noTailscale
        case noPassword
        case listening(host: String, port: UInt16)
        case failed(String)
    }

    static let shared = MirrorServerStatus()
    var state: State = .off
}

/// Listens for remote Canopy attach clients and fans shim traffic over TCP NDJSON.
@MainActor
final class MirrorServer {
    private let store: SessionStore
    private var listener: NWListener?
    /// The running server, for Settings; `NSApp.delegate` is not the adaptor's instance (see memory).
    private(set) static weak var current: MirrorServer?
    private var connections: [MirrorConnection] = []
    /// The address the listener has actually reached `.ready` on; nil while binding or after a failure.
    private(set) var boundAddress: (host: String, port: UInt16)?
    /// The address a not-yet-ready listener is binding; a second start for it must not cancel the first.
    private(set) var pendingAddress: (host: String, port: UInt16)?
    /// Read once per bind so an attach never touches the Keychain; `resetPassword` replaces it.
    fileprivate var token: String

    init(store: SessionStore, token: String) {
        self.store = store
        self.token = token
        MirrorServer.current = self
    }

    /// Mints a new password and drops every attached client; false leaves the old password in force.
    static func resetPassword() -> Bool {
        guard let token = MirrorAccess.resetToken() else { return false }
        current?.token = token
        current?.dropAllConnections()
        return true
    }

    private func dropAllConnections() {
        for connection in connections {
            connection.cancelFromServer()
        }
        connections.removeAll()
    }

    func start(host: String, port: UInt16) {
        stop()
        pendingAddress = (host, port)
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        logger.notice("[mirror-server] listening on \(host, privacy: .public):\(port)")
                        self.boundAddress = (host, port)
                        self.pendingAddress = nil
                        MirrorServerStatus.shared.state = .listening(host: host, port: port)
                    case .waiting(let error), .failed(let error):
                        logger.error("[mirror-server] listener cannot bind \(host, privacy: .public):\(port): \(error.localizedDescription, privacy: .public)")
                        self.boundAddress = nil
                        self.pendingAddress = nil
                        MirrorServerStatus.shared.state = .failed(error.localizedDescription)
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            logger.error("[mirror-server] start failed: \(error.localizedDescription, privacy: .public)")
            MirrorServerStatus.shared.state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        for connection in connections {
            connection.cancelFromServer()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundAddress = nil
        pendingAddress = nil
    }

    /// Whether any connection is still mirroring this session, so its deferred images must stay.
    fileprivate func isMirroring(sessionId: String) -> Bool {
        connections.contains { $0.attachedSessionId == sessionId }
    }

    fileprivate func remove(_ connection: MirrorConnection) {
        connections.removeAll { $0 === connection }
    }

    private func accept(_ connection: NWConnection) {
        let mirror = MirrorConnection(connection: connection, store: store, server: self)
        connections.append(mirror)
        mirror.start()
    }
}

/// One accepted TCP client. First NDJSON line must be `attach`; later lines are webview→host frames.
@MainActor
final class MirrorConnection: MirrorSink {
    // Touched from the Network queue in `scheduleReceive`; NWConnection is
    // thread-safe and the line buffer is locked internally.
    nonisolated(unsafe) private let connection: NWConnection
    nonisolated(unsafe) private let lineBuffer = NDJSONLineBuffer(acceptsCompressed: false)
    private let store: SessionStore
    private weak var server: MirrorServer?
    private weak var shim: ShimProcess?
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorConnection")
    private var didAttach = false
    /// True when the attach came from another Mac's Canopy (not the phone).
    /// A Mac client gets files, usage and `open` redirects a phone does not;
    /// see `fetchesImages` for the image rewrite.
    private(set) var isMacClient = false
    /// True when a Mac client's attach said it serves `canopy-asset` image URLs (`"images": true`),
    /// so its replay can carry them in place of base64 the way a phone's does.
    private(set) var fetchesImages = false
    /// The session this connection attached to; images are only served under it.
    fileprivate private(set) var attachedSessionId = ""

    /// The peer's address, so the mirrored session's `open` lands on the
    /// screen its watcher is sitting at. Only a Mac gets one — the phone has
    /// no `open` to run.
    ///
    /// IPv4 and hostnames only. An IPv6 peer is declined rather than
    /// reformatted: `scp` wants it bracketed and a link-local one needs its
    /// scope, and a host guessed wrong here ships the file nowhere and says
    /// nothing. Declining costs one file opened on this screen instead.
    /// Set from the attach's `files: true`; a client that did not ask never
    /// sees a `MirrorFileWire` frame, so an older Mac does not post a third
    /// of a megabyte of base64 into its page. Its files then open here, as
    /// they did before 2.43.
    private var filesRequested = false
    var acceptsFileTransfers: Bool { isMacClient && filesRequested }

    var openRedirectHost: String? {
        guard isMacClient, case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return address.debugDescription
        case .name(let name, _): return name
        default: return nil
        }
    }
    /// Feeds a client that asked for the status bar at attach; nil for one that did not.
    private var statusPublisher: MirrorStatusPublisher?
    /// Feeds a Mac client that asked for the session's account usage at attach.
    private var usagePublisher: MirrorUsagePublisher?
    /// True once the client's `attach` asked for `MirrorWire` compression. Written on the main
    /// actor before the first send is enqueued; every send captures it by value on the way out.
    private var compressOutbound = false
    private var cleanedUp = false

    /// Whether a client identity gets the phone's replay trim / image rewrite.
    /// Absent `client` (older phones) keeps them; `"mac"` skips them.
    nonisolated static func appliesPhoneReplayRewrites(client: String?) -> Bool {
        client != "mac"
    }

    init(connection: NWConnection, store: SessionStore, server: MirrorServer) {
        self.connection = connection
        self.store = store
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                logger.error("[mirror-server] connection failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    self?.cleanup()
                }
            case .cancelled:
                Task { @MainActor in
                    self?.cleanup()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        scheduleReceive()
    }

    func cancelFromServer() {
        connection.cancel()
        cleanup()
    }

    func deliver(_ payload: [String: Any]) {
        sendJSONObject(payload)
    }

    // MARK: - Read path (queue → main)

    nonisolated private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // `DispatchQueue.main` is FIFO; a Task per line is not, and `attach` must be handled first.
            if let error {
                logger.error("[mirror-server] receive error: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { MainActor.assumeIsolated { self.closeFromPeer() } }
                return
            }
            if let data, !data.isEmpty {
                guard let frames = self.lineBuffer.append(data), let lines = NDJSONLineBuffer.lines(from: frames) else {
                    logger.error("[mirror-server] unreadable frame (over \(NDJSONLineBuffer.maxLineBytes) bytes, a bad Z header, or a Z frame this side does not take); closing")
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.closeFromPeer() } }
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(self.handleLineData) } }
            }
            if isComplete {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.closeFromPeer() } }
                return
            }
            self.scheduleReceive()
        }
    }

    private func handleLineData(_ data: Data) {
        guard !data.isEmpty, !cleanedUp else { return }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.error("[mirror-server] bad JSON: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let dict = object as? [String: Any] else {
            logger.error("[mirror-server] JSON root is not an object")
            return
        }
        if !didAttach {
            handleAttach(dict)
            return
        }
        if dict["type"] as? String == "asset_request" {
            serveAsset(dict)
            return
        }
        shim?.receiveFromMirror(dict, from: self)
    }

    private func handleAttach(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String, type == "attach",
              let sessionId = dict["sessionId"] as? String else {
            logger.error("[mirror-server] attach refused: first line is not an attach (type=\(dict["type"] as? String ?? "nil", privacy: .public))")
            failAttach("expected attach")
            return
        }
        guard let provided = dict["token"] as? String,
              let expected = server?.token,
              MirrorAccess.tokensMatch(provided, expected)
        else {
            logger.error("[mirror-server] attach refused: wrong or missing password")
            failAttach("unauthorized")
            return
        }
        let open = store.openSessions.map { "\($0.resumeId)(shim=\($0.shim != nil))" }.joined(separator: ", ")
        guard let shim = store.openSessions.first(where: { $0.resumeId == sessionId })?.shim else {
            logger.error("[mirror-server] attach refused: no shim for \(sessionId, privacy: .public); open sessions: \(open, privacy: .public)")
            failAttach("no such session")
            return
        }
        didAttach = true
        isMacClient = !Self.appliesPhoneReplayRewrites(client: dict["client"] as? String)
        self.shim = shim
        attachedSessionId = sessionId
        compressOutbound = dict["compress"] as? String == MirrorWire.compressionName
        filesRequested = dict["files"] as? Bool == true
        fetchesImages = isMacClient && dict["images"] as? Bool == true
        // Only for a client that says it will use the answer; an older phone asks for the transcript itself.
        let prefetchId = (dict["prefetch"] as? Bool == true) ? "canopy-prefetch-\(UUID().uuidString)" : ""
        // Sent before `attachMirror`, so it is the first line the client sees after attaching.
        sendJSONObject([
            "type": "attach_ok",
            "sessionId": sessionId,
            "html": WebViewContainer.entryHTML(resumeSessionId: sessionId, includeKeychainAuth: shim.claudeAccount == nil) {
                "\(Self.assetScheme)://ext/\($0)"
            },
            "userScripts": WebViewContainer.sessionUserScripts.map { ["source": $0.source, "atDocumentStart": $0.atDocumentStart] },
            // Lets the phone cache the assets it fetches, keyed by the extension they came from.
            "extensionVersion": CCExtension.extensionVersion() ?? "",
            // The replay is already being fetched; the phone answers its page's get_session_request with it.
            "prefetchedSessionRequestId": prefetchId,
            // Confirms the negotiation for a client that wants to check; none reads it yet.
            "compress": compressOutbound ? MirrorWire.compressionName : "",
        ])
        shim.attachMirror(self)
        if !prefetchId.isEmpty {
            // Starts the extension reading the transcript while the phone is still loading the page.
            shim.receiveFromMirror(Self.prefetchRequest(sessionId: sessionId, requestId: prefetchId), from: self)
        }
        // Opt-in: a client that does not know the frame would post it into its page as a webview message.
        if dict["status"] as? Bool == true, let data = shim.statusBarData {
            let publisher = MirrorStatusPublisher(data: data) { [weak self] payload in self?.sendJSONObject(payload) }
            statusPublisher = publisher
            publisher.start()
        }
        if isMacClient, dict["usage"] as? Bool == true {
            let publisher = MirrorUsagePublisher(shim: shim) { [weak self] payload in self?.sendJSONObject(payload) }
            usagePublisher = publisher
            publisher.start()
        }
        logger.notice("[mirror-server] attached \(sessionId, privacy: .public)")
    }

    /// The request a page sends for its transcript, as captured from the extension webview (2.1.270).
    nonisolated static func prefetchRequest(sessionId: String, requestId: String) -> [String: Any] {
        ["type": "request", "requestId": requestId,
         "request": ["type": "get_session_request", "sessionId": sessionId, "purpose": "transcript_open"]]
    }

    /// The URL scheme a remote client serves extension assets under.
    static let assetScheme = "canopy-asset"

    /// Answers one `asset_request` with a file under the extension's `webview/` or `resources/`.
    private func serveAsset(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return }
        var reply: [String: Any] = ["type": "asset_response", "id": id]
        defer { sendJSONObject(reply) }
        // `img/` is the thumbnail size; `imgfull/` the original bytes, which a Mac asks for to open one full size.
        if let path = dict["path"] as? String, path.hasPrefix("img/") || path.hasPrefix("imgfull/") {
            let full = path.hasPrefix("imgfull/")
            // Scoped to this connection's own session, so one mirror cannot pull another session's images.
            let key = MirrorImageStore.key(sessionId: attachedSessionId, image: String(path.drop { $0 != "/" }.dropFirst()))
            guard let image = full ? MirrorImageStore.original(key: key) : MirrorImageStore.jpeg(key: key) else {
                logger.error("[mirror-server] image \(key, privacy: .public) not in store")
                reply["error"] = "not found"
                return
            }
            reply["mime"] = image.mime
            reply["base64"] = image.data.base64EncodedString()
            return
        }
        guard let path = dict["path"] as? String, let root = CCExtension.extensionPath()?.standardizedFileURL else {
            reply["error"] = "no extension"
            return
        }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let allowed = ["webview/", "resources/"].contains { file.path.hasPrefix(root.path + "/" + $0) }
        guard allowed, let data = FileManager.default.contents(atPath: file.path) else {
            logger.error("[mirror-server] asset refused: \(path, privacy: .public)")
            reply["error"] = "not found"
            return
        }
        reply["mime"] = Self.mimeType(forExtension: file.pathExtension)
        reply["base64"] = data.base64EncodedString()
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }

    private func failAttach(_ message: String) {
        // Cancel only once the refusal has left the send queue; cancelling
        // right after `send` drops the line (measured: the client saw a
        // bare reset and no `attach_error`).
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "attach_error", "message": message])) ?? Data()
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        cleanup()
    }

    private func sendJSONObject(_ payload: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("[mirror-server] send serialize failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Encoded off the main thread; one serial path keeps a small line from overtaking a large one.
        let compress = compressOutbound
        queue.async { [connection] in
            let frame = MirrorWire.encode(line: data, compress: compress)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    logger.error("[mirror-server] send failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func closeFromPeer() {
        connection.cancel()
        cleanup()
    }

    private func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        statusPublisher?.stop()
        statusPublisher = nil
        usagePublisher?.stop()
        usagePublisher = nil
        shim?.detachMirror(self)
        shim = nil
        let server = self.server
        server?.remove(self)
        if !attachedSessionId.isEmpty, server?.isMirroring(sessionId: attachedSessionId) != true {
            MirrorImageStore.discard(sessionId: attachedSessionId)
        }
        logger.notice("[mirror-server] detached")
    }
}

/// Read-tool images deferred out of a remote client's replay, served when its thumbnail asks for them.
///
/// Keyed by session and content, so a mirror can only ask for images from the session it attached to.
@MainActor
enum MirrorImageStore {
    static let maxPixelSize = 768
    private static var sources: [String: [String: Any]] = [:]

    static func key(sessionId: String, image: String) -> String { "\(sessionId)/\(image)" }

    /// Kept for as long as a mirror of that session is attached: a thumbnail can ask for an
    /// image minutes after the replay, and the replay no longer carries the bytes to fall back on.
    static func put(key: String, source: [String: Any]) {
        guard sources[key] == nil else { return }
        sources[key] = source
    }

    /// Drops everything deferred for one session, once nothing is mirroring it.
    static func discard(sessionId: String) {
        let prefix = "\(sessionId)/"
        let dropped = sources.keys.filter { $0.hasPrefix(prefix) }
        guard !dropped.isEmpty else { return }
        for key in dropped { sources[key] = nil }
        logger.notice("[mirror-server] released \(dropped.count, privacy: .public) deferred image(s)")
    }

    /// The image as the transcript holds it.
    static func original(key: String) -> (data: Data, mime: String)? {
        guard let source = sources[key], let encoded = source["data"] as? String, let bytes = Data(base64Encoded: encoded) else { return nil }
        return (bytes, source["media_type"] as? String ?? "application/octet-stream")
    }

    /// The image at phone size: a JPEG with a long edge of `maxPixelSize`, or the original bytes when re-encoding does not shrink them.
    static func jpeg(key: String) -> (data: Data, mime: String)? {
        guard let source = sources[key], let encoded = source["data"] as? String, let bytes = Data(base64Encoded: encoded) else { return nil }
        if let smaller = RosterImageUploader.thumbnail(from: bytes, maxPixelSize: maxPixelSize, quality: 0.6), smaller.count < bytes.count {
            return (smaller, "image/jpeg")
        }
        return (bytes, source["media_type"] as? String ?? "application/octet-stream")
    }
}
