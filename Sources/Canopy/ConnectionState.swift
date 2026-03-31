import Foundation
import Observation

enum ConnectionStatus: Equatable {
    case connected
    case reconnecting(attempt: Int)
    case reconnectFailed
}

@Observable
final class ConnectionState {
    var status: ConnectionStatus = .connected
    /// Called when user taps "Retry" button. Set by Coordinator.
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
        }
    }
}
