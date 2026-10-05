import Foundation
import Observation

enum ConnectionStatus: Equatable {
    case connected
    case reconnecting(attempt: Int)
    case reconnectFailed
    /// The machine announced a restart for an update; the pane re-attaches when it is back.
    case awaitingRestart(machine: String)
    /// A Stop session asked for; waiting for the Mac that runs it to answer.
    case stopping
}

@Observable
final class ConnectionState {
    var status: ConnectionStatus = .connected
    /// Called when user taps "Retry". Set by the pane that owns the connection.
    var onRetry: (() -> Void)?

    var isOverlayVisible: Bool {
        status != .connected
    }

    var statusMessage: String {
        switch status {
        case .connected:
            return ""
        case .reconnecting(let attempt):
            return "Reconnecting... (\(attempt)/3)"
        case .reconnectFailed:
            return "Could not reconnect"
        case .awaitingRestart(let machine):
            return "\(machine) is restarting for an update. Reconnecting…"
        case .stopping:
            return "Waiting for it to stop…"
        }
    }
}
