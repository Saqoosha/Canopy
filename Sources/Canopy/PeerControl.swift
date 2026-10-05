import Foundation

/// One control request to another Mac's daemon, over TCP with its pairing
/// password: connect, ask, disconnect. For verbs a pane or row sends once
/// (`stop_session`), where holding a connection open would buy nothing.
@MainActor
enum PeerControl {
    enum Failure: Error, Equatable {
        /// No usable pairing for that Mac in Settings › Remote.
        case unpaired
        /// `hello` failed: the server's refusal, or nil when it never answered.
        case unreachable(refusal: String?)
        case refused(String)
        case timedOut
        case disconnected

        func message(machineName: String) -> String {
            switch self {
            case .unpaired: "Paste \(machineName)'s connection in Settings › Remote first."
            case .unreachable(refusal: "unauthorized"): "\(machineName) rejected the password. Paste its connection again in Settings › Remote."
            case .unreachable(refusal: let refusal?): "\(machineName) refused the connection: \(refusal)"
            case .unreachable(refusal: nil): "Could not reach \(machineName). Is its live mirror on?"
            case .refused(let reason): "\(machineName) refused: \(reason)"
            case .timedOut: "\(machineName) did not answer."
            case .disconnected: "Lost the connection to \(machineName)."
            }
        }
    }

    static func request(machineId: String, _ verb: String, _ params: [String: Any]) async -> Result<[String: Any], Failure> {
        guard let address = CanopySettings.shared.mirrorPeers[machineId],
              let hostPort = MirrorAccess.parseHostPort(address),
              let token = MirrorAccess.peerToken(machineId: machineId) else {
            return .failure(.unpaired)
        }
        let client = ControlClient(endpoint: .tcp(host: hostPort.host, port: hostPort.port), token: token, subscribes: false)
        client.start()
        defer { client.stop() }
        guard await client.waitUntilReady() else { return .failure(.unreachable(refusal: client.lastRefusal)) }
        switch await client.request(verb, params) {
        case .success(let result): return .success(result)
        case .failure(.refused(let reason)): return .failure(.refused(reason))
        case .failure(.timedOut): return .failure(.timedOut)
        case .failure(.disconnected): return .failure(.disconnected)
        }
    }
}
