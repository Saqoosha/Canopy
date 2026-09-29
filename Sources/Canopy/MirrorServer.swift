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
    /// The daemon's local Unix socket, alongside the TCP `listener`.
    private var localListener: NWListener?
    private var localSocketPath: String?
    /// The address the listener has actually reached `.ready` on; nil while binding or after a failure.
    private(set) var boundAddress: (host: String, port: UInt16)?
    /// The address a not-yet-ready listener is binding; a second start for it must not cancel the first.
    private(set) var pendingAddress: (host: String, port: UInt16)?
    /// Read once per bind so an attach never touches the Keychain; `resetPassword` replaces it.
    fileprivate var token: String
    /// Daemon only: a `hello` first line opens a control connection. The GUI's
    /// mirror listener keeps refusing it, so its panes cannot be stopped from outside.
    var acceptsControl = false
    /// Daemon only: re-read the password from the Keychain on each TCP
    /// connection, because a reset happens in the GUI process.
    var refreshesToken = false
    /// This Mac's bypass-permissions opt-in, asked per `open_session`.
    var bypassAllowed: () -> Bool = { false }
    /// Daemon only: the local socket stopped listening after it was up.
    var onLocalFailure: (() -> Void)?

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

    /// A reset in the GUI replaces the Keychain item; the old password must stop working here too.
    func refreshToken() {
        let current = MirrorAccess.token(createIfMissing: false) ?? ""
        guard current != token else { return }
        logger.notice("[mirror-server] password changed; dropping TCP clients")
        token = current
        for connection in connections where !connection.trustsPeer {
            connection.cancelFromServer()
        }
        connections.removeAll { !$0.trustsPeer }
    }

    private func dropAllConnections() {
        for connection in connections {
            connection.cancelFromServer()
        }
        connections.removeAll()
    }

    func start(host: String, port: UInt16) {
        stopTCP()
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
                    self?.accept(connection, trustsPeer: false)
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
        stopTCP()
    }

    /// Stops the TCP listener and its connections; local-socket clients stay.
    func stopTCP() {
        for connection in connections where !connection.trustsPeer {
            connection.cancelFromServer()
        }
        connections.removeAll { !$0.trustsPeer }
        listener?.cancel()
        listener = nil
        boundAddress = nil
        pendingAddress = nil
    }

    /// The daemon's own socket. Trusted by file permission (0600), so a
    /// connection from it needs no password. False when it cannot listen,
    /// including when another process already accepts on `socketPath`.
    @discardableResult
    func startLocal(socketPath: String) -> Bool {
        stopLocal()
        if DaemonPaths.socketIsLive(path: socketPath) {
            logger.error("[mirror-server] another daemon is already serving the local socket")
            return false
        }
        // A crashed daemon leaves its socket file; binding over it fails with EADDRINUSE.
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socketPath)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.localListener === listener else { return }
                    switch state {
                    case .ready:
                        chmod(socketPath, 0o600)
                        logger.notice("[mirror-server] local socket ready")
                    case .waiting(let error), .failed(let error):
                        logger.error("[mirror-server] local socket cannot bind: \(error.localizedDescription, privacy: .public)")
                        self.onLocalFailure?()
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, trustsPeer: true) }
            }
            listener.start(queue: .main)
            localListener = listener
            localSocketPath = socketPath
        } catch {
            logger.error("[mirror-server] local socket start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    func stopLocal() {
        for connection in connections where connection.trustsPeer {
            connection.cancelFromServer()
        }
        connections.removeAll { $0.trustsPeer }
        localListener?.cancel()
        localListener = nil
        if let path = localSocketPath { try? FileManager.default.removeItem(atPath: path) }
        localSocketPath = nil
    }

    /// Whether any connection is still mirroring this session, so its deferred images must stay.
    fileprivate func isMirroring(sessionId: String) -> Bool {
        connections.contains { $0.attachedSessionId == sessionId }
    }

    fileprivate func remove(_ connection: MirrorConnection) {
        connections.removeAll { $0 === connection }
    }

    private func accept(_ connection: NWConnection, trustsPeer: Bool) {
        if !trustsPeer, refreshesToken { refreshToken() }
        let mirror = MirrorConnection(connection: connection, store: store, server: self, trustsPeer: trustsPeer)
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
    /// Set once the first line was `hello`; every later line goes here instead of to a shim.
    private var control: ControlSession?

    /// Whether a client identity is a phone. Absent `client` (older phones) is one; `"mac"` is not.
    nonisolated static func appliesPhoneReplayRewrites(client: String?) -> Bool {
        client != "mac"
    }

    /// True for a connection from the daemon's local Unix socket, which the
    /// file mode already restricts to this user. Every password check below
    /// passes for it.
    let trustsPeer: Bool

    init(connection: NWConnection, store: SessionStore, server: MirrorServer, trustsPeer: Bool) {
        self.connection = connection
        self.store = store
        self.server = server
        self.trustsPeer = trustsPeer
    }

    /// The mirror password check, which a local-socket peer skips.
    private func isAuthorized(_ dict: [String: Any]) -> Bool {
        if trustsPeer { return true }
        guard let provided = dict["token"] as? String, let expected = server?.token else { return false }
        return MirrorAccess.tokensMatch(provided, expected)
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
        if let control {
            control.handle(dict)
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

    /// The one line a `list_recents` connection gets before it is closed.
    /// Same password as an attach: it names every project folder here.
    private func answerRecents(_ dict: [String: Any]) {
        guard isAuthorized(dict) else {
            logger.error("[mirror-server] list_recents refused: wrong or missing password")
            failAttach("unauthorized")
            return
        }
        let open = Set(store.openSessions.map(\.resumeId))
        let sessions = store.recents.filter { $0.canOpen && !open.contains($0.id) && !store.hiddenIds.contains($0.id) }
        let folders = RecentDirectories.load().filter { FileManager.default.fileExists(atPath: $0.path) }
        let data = (try? JSONSerialization.data(withJSONObject: MirrorRecents.replyPayload(sessions: sessions, folders: folders))) ?? Data()
        // Closed only once the line has left, for `failAttach`'s measured reason.
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        cleanup()
        logger.notice("[mirror-server] list_recents answered: \(min(sessions.count, MirrorRecents.maxSessions)) session(s), \(min(folders.count, MirrorRecents.maxFolders)) folder(s)")
    }

    /// The shim an `open` request asks for, started with no pane on this Mac,
    /// or the `attach_error` message saying why there is none.
    private func startRequestedSession(_ request: MirrorOpenRequest, sessionId: String) -> Result<ShimProcess, OpenFailure> {
        let shim: ShimProcess?
        switch request {
        case .resume:
            if store.openSessions.contains(where: { $0.resumeId == sessionId }) {
                // Open but dormant: it already knows its own folder.
                shim = store.startHeadlessSession(resumeId: sessionId)
            } else if let entry = store.recents.first(where: { $0.id == sessionId }), entry.canOpen {
                shim = store.startHeadlessSession(directory: entry.projectDirectory, resumeId: sessionId,
                                                  isExistingTranscript: true, title: entry.title)
            } else {
                logger.error("[mirror-server] open refused: \(sessionId, privacy: .public) is not a session here")
                return .failure(OpenFailure(MirrorOpenRequest.notOpenable))
            }
        case .new(let cwd):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                logger.error("[mirror-server] open refused: no folder at \(cwd, privacy: .private)")
                return .failure(OpenFailure(MirrorOpenRequest.notOpenable))
            }
            shim = store.startHeadlessSession(directory: URL(fileURLWithPath: cwd), resumeId: sessionId,
                                              isExistingTranscript: false, title: nil)
        }
        return shim.map { .success($0) } ?? .failure(OpenFailure(MirrorOpenRequest.startFailed))
    }

    private struct OpenFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func handleAttach(_ dict: [String: Any]) {
        if dict["type"] as? String == ControlProtocol.helloType {
            openControl(dict)
            return
        }
        if dict["type"] as? String == MirrorRecents.listType {
            answerRecents(dict)
            return
        }
        guard let type = dict["type"] as? String, type == "attach",
              let sessionId = dict["sessionId"] as? String else {
            logger.error("[mirror-server] attach refused: first line is not an attach (type=\(dict["type"] as? String ?? "nil", privacy: .public))")
            failAttach("expected attach")
            return
        }
        guard isAuthorized(dict) else {
            logger.error("[mirror-server] attach refused: wrong or missing password")
            failAttach("unauthorized")
            return
        }
        let open = store.openSessions.map { "\($0.resumeId)(shim=\($0.shim != nil))" }.joined(separator: ", ")
        var existing = store.openSessions.first(where: { $0.resumeId == sessionId })?.shim.flatMap { $0.isLive ? $0 : nil }
        if existing == nil, let request = MirrorOpenRequest(wire: dict["open"] as? [String: Any]) {
            switch startRequestedSession(request, sessionId: sessionId) {
            case .success(let shim): existing = shim
            case .failure(let failure):
                failAttach(failure.message)
                return
            }
        }
        guard let shim = existing else {
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
            // The id the roster publishes this session under. A new session's
            // `sessionId` above is a placeholder the CLI's id replaces, and
            // this is what lets the client follow it.
            "hostSessionId": shim.boundSession?.id.uuidString ?? "",
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
    nonisolated static let assetScheme = "canopy-asset"

    /// Answers one `asset_request` with a file under the extension's `webview/` or `resources/`.
    private func serveAsset(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return }
        var reply: [String: Any] = ["type": "asset_response", "id": id]
        defer { sendJSONObject(reply) }
        if let path = dict["path"] as? String, let request = Self.imageAssetRequest(path: path) {
            // Scoped to this connection's own session, so one mirror cannot pull another session's images.
            let key = MirrorImageStore.key(sessionId: attachedSessionId, image: request.image)
            guard let image = request.full ? MirrorImageStore.original(key: key) : MirrorImageStore.jpeg(key: key) else {
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

    /// A deferred-image request: `img/<id>` at thumbnail size, `imgfull/<id>` the original bytes a Mac asks for
    /// to open one full size. Nil for any other path.
    nonisolated static func imageAssetRequest(path: String) -> (image: String, full: Bool)? {
        if path.hasPrefix("imgfull/") { return (String(path.dropFirst("imgfull/".count)), true) }
        if path.hasPrefix("img/") { return (String(path.dropFirst("img/".count)), false) }
        return nil
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

    /// A `hello` first line makes this a control connection (`ControlSession`).
    private func openControl(_ dict: [String: Any]) {
        guard server?.acceptsControl == true else {
            logger.error("[mirror-server] hello refused: this listener has no control API")
            failHello("no control API here")
            return
        }
        switch ControlProtocol.checkHello(dict, trustsPeer: trustsPeer, expectedToken: server?.token) {
        case .ok:
            control = ControlSession(store: store, allowBypass: server?.bypassAllowed ?? { false }) { [weak self] payload in
                self?.sendJSONObject(payload)
            }
            didAttach = true
            compressOutbound = dict["compress"] as? String == MirrorWire.compressionName
            sendJSONObject(["type": "hello_ok", "protocolVersion": ControlProtocol.version,
                            "machineId": MachineIdentity.stableId() ?? ""])
            logger.notice("[mirror-server] control connection opened (local=\(self.trustsPeer))")
        case .unauthorized:
            logger.error("[mirror-server] hello refused: wrong or missing password")
            failHello("unauthorized")
        case .versionMismatch(let client, let server):
            logger.error("[mirror-server] hello refused: protocol \(client) vs \(server)")
            failHello("protocol version \(client) is not \(server)")
        }
    }

    private func failHello(_ message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "hello_error", "message": message])) ?? Data()
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        cleanup()
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
        control?.stop()
        control = nil
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

    /// The image at thumbnail size: a JPEG with a long edge of `maxPixelSize`, or the original bytes when re-encoding does not shrink them.
    static func jpeg(key: String) -> (data: Data, mime: String)? {
        guard let source = sources[key], let encoded = source["data"] as? String, let bytes = Data(base64Encoded: encoded) else { return nil }
        if let smaller = RosterImageUploader.thumbnail(from: bytes, maxPixelSize: maxPixelSize, quality: 0.6), smaller.count < bytes.count {
            return (smaller, "image/jpeg")
        }
        return (bytes, source["media_type"] as? String ?? "application/octet-stream")
    }
}
