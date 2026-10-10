import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonReaper")

/// Stops daemon sessions nobody is using (`SessionReaper`). Daemon mode
/// only; the GUI app never starts one.
@MainActor
final class DaemonReaper {
    private let store: SessionStore
    private var timer: Timer?

    init(store: SessionStore) {
        self.store = store
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
        // Read per tick: the GUI changes it in settings.json, which the daemon re-reads.
        guard let limit = CanopySettings.shared.sessionIdleLimit else { return }
        let now = Date()
        for session in store.openSessions {
            guard let shim = session.shim else { continue }
            let inputs = shim.reaperInputs
            guard SessionReaper.shouldReap(inputs, now: now, limit: limit) else { continue }
            logger.notice("reaping \(session.resumeId, privacy: .public): quiet \(Int(now.timeIntervalSince(inputs.quietSince)))s with no client")
            // With no transcript there is nothing to resume, so its row may go.
            if case .local(let dir) = session.origin,
               session.resumeIdIsExistingTranscript || ClaudeSessionHistory.sessionFileExists(id: session.resumeId, directory: dir) {
                ReapedSessions.shared.insert(session.resumeId)
            }
            store.closeSession(session.id, keepingFailure: false)
        }
    }
}
