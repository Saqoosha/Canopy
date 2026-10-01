import Foundation
import Network

/// How a mirror pane on another Mac gets back to a session after that Mac's daemon
/// announced `daemon_restarting`. The pane waits for the listener before re-attaching:
/// `restartSession` puts it back in `.spawning`, where a failed connection closes it.
enum RestartReattach {
    static let interval: TimeInterval = 2
    /// Far above the gap it waits out. Measured 2026-10-01 with `launchctl kickstart -k` on
    /// the daemon: the old process's last connection closed at 47.733 and the new one was
    /// listening at 47.838. An upgrade adds `restartIfUpgraded`'s 1 s before exit; the
    /// slack covers a slow shutdown, not a slow start.
    static let budget: TimeInterval = 60

    nonisolated static func attempts(interval: TimeInterval, budget: TimeInterval) -> Int {
        max(1, Int(budget / interval))
    }

    /// True when a TCP connection to the listener becomes ready within `timeout`.
    /// `.waiting` counts as down: a refused connection lands there rather than in `.failed`.
    nonisolated static func listenerIsUp(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "sh.saqoo.Canopy.RestartReattach")
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
