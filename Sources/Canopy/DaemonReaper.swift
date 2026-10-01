import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonReaper")

/// Stops daemon sessions nobody is using (`SessionReaper`). Daemon mode
/// only; the GUI app never starts one.
@MainActor
final class DaemonReaper {
    private let store: SessionStore
    private let limit: TimeInterval
    private var timer: Timer?

    init(store: SessionStore, limit: TimeInterval = SessionReaper.defaultIdleLimit) {
        self.store = store
        self.limit = limit
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        for session in store.openSessions {
            guard let shim = session.shim else { continue }
            let inputs = shim.reaperInputs
            guard SessionReaper.shouldReap(inputs, now: now, limit: limit) else { continue }
            logger.notice("reaping \(session.resumeId, privacy: .public): quiet \(Int(now.timeIntervalSince(inputs.quietSince)))s with no client")
            store.closeSession(session.id, keepingFailure: false)
        }
    }
}
