import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlClient")

/// The GUI's control connection to a daemon: requests with one response each,
/// and `session_state` pushes after `subscribe`. Reconnects on its own.
@MainActor
final class ControlClient {
    enum Failure: Error, Equatable { case refused(String), disconnected, timedOut }

    /// How long a request waits for its response before failing.
    static let requestTimeout: Duration = .seconds(15)

    /// Request ids and the one response each may receive.
    struct Correlator {
        private var next = 0
        private var pending: [String] = []

        mutating func begin() -> String {
            next += 1
            let id = "c\(next)"
            pending.append(id)
            return id
        }

        mutating func finish(_ response: [String: Any]) -> (id: String, result: Result<[String: Any], Failure>)? {
            guard let id = response["id"] as? String, let index = pending.firstIndex(of: id) else { return nil }
            pending.remove(at: index)
            if let error = response["error"] as? String { return (id, .failure(.refused(error))) }
            return (id, .success(response["result"] as? [String: Any] ?? [:]))
        }

        /// Every id still waiting, in the order they were sent; clears them.
        mutating func failAll() -> [String] {
            defer { pending.removeAll() }
            return pending
        }
    }

    /// The rows, and whether every row in the push could be read.
    var onSessionState: (([ControlProtocol.SessionRow], Bool) -> Void)?

    private let endpoint: MirrorEndpoint
    private let token: String?
    private var connection: NWConnection?
    private var buffer = NDJSONLineBuffer(acceptsCompressed: true)
    private var correlator = Correlator()
    private var waiters: [String: CheckedContinuation<Result<[String: Any], Failure>, Never>] = [:]
    private var ready = false
    private var stopped = false
    /// Set by `hello_error`: the daemon refused this client, and retrying every 2 s would only repeat that.
    private var refused = false

    init(endpoint: MirrorEndpoint, token: String?) {
        self.endpoint = endpoint
        self.token = token
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        ready = false
        failPending()
    }

    func request(_ verb: String, _ params: [String: Any] = [:]) async -> Result<[String: Any], Failure> {
        guard ready else { return .failure(.disconnected) }
        let id = correlator.begin()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard !Task.isCancelled else { return }
            self?.resolve(id, with: .failure(.timedOut))
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            if !send(["type": "request", "id": id, "verb": verb, "params": params]) {
                resolve(id, with: .failure(.disconnected))
            }
        }
    }

    private func resolve(_ id: String, with result: sending Result<[String: Any], Failure>) {
        waiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func connect() {
        guard !stopped else { return }
        buffer = NDJSONLineBuffer(acceptsCompressed: true)
        let connection = NWConnection(to: endpoint.nwEndpoint, using: endpoint.parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, of: connection) }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            var hello: [String: Any] = ["type": "hello", "protocolVersion": ControlProtocol.version, "client": "mac"]
            if let token { hello["token"] = token }
            send(hello)
        case .failed:
            connection.cancel()
        case .cancelled:
            dropped()
        case .waiting:
            // The socket is not there yet (daemon starting); a fresh attempt beats waiting on this one.
            connection.cancel()
        default:
            break
        }
    }

    private func dropped() {
        if ready { logger.notice("control connection dropped") }
        ready = false
        connection = nil
        failPending()
        guard !stopped, !refused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
    }

    private func failPending() {
        for id in correlator.failAll() {
            waiters.removeValue(forKey: id)?.resume(returning: .failure(.disconnected))
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data, !data.isEmpty {
                    guard let frames = self.buffer.append(data), let lines = NDJSONLineBuffer.lines(from: frames) else {
                        logger.error("unreadable frame from the daemon; reconnecting")
                        connection.cancel()
                        return
                    }
                    lines.forEach(self.handleLine)
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch dict["type"] as? String {
        case "hello_ok":
            ready = true
            logger.notice("control connection ready")
            Task { [weak self] in
                guard let self else { return }
                if case .failure(let failure) = await self.request("subscribe") {
                    logger.error("subscribe failed: \(String(describing: failure), privacy: .public)")
                }
            }
        case "hello_error":
            // Terminal: a version mismatch or a refused password does not heal by retrying.
            logger.error("daemon refused hello, not retrying: \(dict["message"] as? String ?? "?", privacy: .public)")
            refused = true
            connection?.cancel()
        case "session_state":
            let raw = dict["sessions"] as? [[String: Any]] ?? []
            let rows = raw.compactMap(ControlProtocol.SessionRow.init(wire:))
            if rows.count != raw.count { logger.error("\(raw.count - rows.count) unreadable session row(s) from the daemon") }
            onSessionState?(rows, rows.count == raw.count)
        case "response":
            if let (id, result) = correlator.finish(dict) { waiters.removeValue(forKey: id)?.resume(returning: result) }
        default:
            break
        }
    }

    /// False when nothing could be sent (no connection, or the payload does not serialize).
    @discardableResult
    private func send(_ payload: [String: Any]) -> Bool {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { error in
            if let error { logger.error("send failed: \(error.localizedDescription, privacy: .public)") }
        })
        return true
    }
}
