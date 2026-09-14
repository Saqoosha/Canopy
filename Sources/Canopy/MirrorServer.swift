#if DEBUG
import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorServer")

/// Listens for remote Canopy attach clients and fans shim traffic over TCP NDJSON.
@MainActor
final class MirrorServer {
    private let store: SessionStore
    private var listener: NWListener?
    private var connections: [MirrorConnection] = []

    init(store: SessionStore) {
        self.store = store
    }

    /// `"8770"` binds loopback only; `"<host>:8770"` binds that one address (e.g. the Tailscale IP).
    static func listenAddress(from raw: String) -> (host: String, port: UInt16)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let port = UInt16(parts[0]), port != 0 else { return nil }
            return ("127.0.0.1", port)
        case 2:
            guard !parts[0].isEmpty, let port = UInt16(parts[1]), port != 0 else { return nil }
            return (String(parts[0]), port)
        default:
            return nil
        }
    }

    func start(host: String, port: UInt16) {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    logger.notice("[mirror-server] listening on \(host, privacy: .public):\(port)")
                case .failed(let error):
                    logger.error("[mirror-server] listener failed: \(error.localizedDescription, privacy: .public)")
                case .cancelled:
                    break
                default:
                    break
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
        }
    }

    func stop() {
        for connection in connections {
            connection.cancelFromServer()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
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
                let lines = self.lineBuffer.append(data)
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
        guard !data.isEmpty else { return }
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
        shim?.receiveFromMirror(dict, from: self)
    }

    private func handleAttach(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String, type == "attach",
              let sessionId = dict["sessionId"] as? String else {
            logger.error("[mirror-server] attach refused: first line is not an attach (type=\(dict["type"] as? String ?? "nil", privacy: .public))")
            failAttach()
            return
        }
        let open = store.openSessions.map { "\($0.resumeId)(shim=\($0.shim != nil))" }.joined(separator: ", ")
        guard let shim = store.openSessions.first(where: { $0.resumeId == sessionId })?.shim else {
            logger.error("[mirror-server] attach refused: no shim for \(sessionId, privacy: .public); open sessions: \(open, privacy: .public)")
            failAttach()
            return
        }
        didAttach = true
        self.shim = shim
        shim.attachMirror(self)
        logger.notice("[mirror-server] attached \(sessionId, privacy: .public)")
    }

    private func failAttach() {
        // Cancel only once the refusal has left the send queue; cancelling
        // right after `send` drops the line (measured: the client saw a
        // bare reset and no `attach_error`).
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "attach_error", "message": "no such session"])) ?? Data()
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
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [Data] = []
        while let range = buffer.range(of: Data([0x0A])) {
            lines.append(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        }
        return lines
    }
}
#endif
