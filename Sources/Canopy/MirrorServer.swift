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
                        MirrorServerStatus.shared.state = .listening(host: host, port: port)
                    case .waiting(let error), .failed(let error):
                        logger.error("[mirror-server] listener cannot bind \(host, privacy: .public):\(port): \(error.localizedDescription, privacy: .public)")
                        self.boundAddress = nil
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
    nonisolated(unsafe) private let lineBuffer = NDJSONLineBuffer()
    private let store: SessionStore
    private weak var server: MirrorServer?
    private weak var shim: ShimProcess?
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorConnection")
    private var didAttach = false
    private var cleanedUp = false

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
                guard let lines = self.lineBuffer.append(data) else {
                    logger.error("[mirror-server] line over \(NDJSONLineBuffer.maxLineBytes) bytes; closing")
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
        self.shim = shim
        // Sent before `attachMirror`, so it is the first line the client sees after attaching.
        sendJSONObject([
            "type": "attach_ok",
            "sessionId": sessionId,
            "html": WebViewContainer.entryHTML(resumeSessionId: sessionId) { "\(Self.assetScheme)://ext/\($0)" },
            "userScripts": WebViewContainer.sessionUserScripts.map { ["source": $0.source, "atDocumentStart": $0.atDocumentStart] },
        ])
        shim.attachMirror(self)
        logger.notice("[mirror-server] attached \(sessionId, privacy: .public)")
    }

    /// The URL scheme a remote client serves extension assets under.
    static let assetScheme = "canopy-asset"

    /// Answers one `asset_request` with a file under the extension's `webview/` or `resources/`.
    private func serveAsset(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return }
        var reply: [String: Any] = ["type": "asset_response", "id": id]
        defer { sendJSONObject(reply) }
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
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { error in
            if let error {
                logger.error("[mirror-server] send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func closeFromPeer() {
        connection.cancel()
        cleanup()
    }

    private func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        shim?.detachMirror(self)
        shim = nil
        server?.remove(self)
        logger.notice("[mirror-server] detached")
    }
}

/// Accumulates socket bytes and yields complete newline-terminated lines.
final class NDJSONLineBuffer: @unchecked Sendable {
    /// Above the largest legitimate line (a base64 `index.js`, ~7 MB); a peer that never sends a newline is cut off here.
    static let maxLineBytes = 16 << 20
    private let lock = NSLock()
    private var buffer = Data()

    /// Complete lines, or nil once an unterminated line exceeds `maxLineBytes`.
    func append(_ chunk: Data) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        guard buffer.count <= Self.maxLineBytes else { return nil }
        var lines: [Data] = []
        while let range = buffer.range(of: Data([0x0A])) {
            lines.append(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        }
        return lines
    }
}
