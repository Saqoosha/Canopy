import Foundation
import Observation
import Security
import os.log

/// Publishes this Mac's panes to the relay whenever they change.
///
/// The tracking shape is `MacroPadController`'s: one `withObservationTracking`
/// pass that reads everything the snapshot needs and re-arms itself. That
/// controller is the precedent for turning `SessionActivity` into an output,
/// and a second shape here would be a second thing to keep correct.
///
/// A snapshot is always FULL. The Durable Object replaces rather than merges,
/// so a dropped update cannot leave a closed pane on the phone forever.
@MainActor
final class RosterPublisher {
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Roster")
    private let store: SessionStore
    private let settings: CanopySettings
    private var task: URLSessionWebSocketTask?
    private var stateSince: [OpenSession.ID: Int] = [:]
    private var lastStates: [OpenSession.ID: String] = [:]
    private var running = false

    init(store: SessionStore, settings: CanopySettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        connectIfConfigured()
        observe()
    }

    func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func observe() {
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.publish()
                self.observe()
            }
        }
    }

    private func connectIfConfigured() {
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return }
        components.path = "/publish"
        components.queryItems = [URLQueryItem(name: "machine", value: machineId)]
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else {
            logger.error("roster endpoint is not a usable URL")
            return
        }
        guard let secret = RosterPublisher.sharedSecret() else {
            // Nothing to authenticate with. Log the decision, never the value.
            logger.notice("roster: no relay secret in the Keychain; not connecting")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task
        logger.notice("roster: connected as \(machineId, privacy: .public)")
    }

    /// The relay secret, from the Keychain.
    ///
    /// **Not from the process environment.** Canopy is launched with `open`,
    /// which gives it no shell environment, so an env var would be empty in
    /// every normal launch and present only when a developer runs the binary
    /// from a terminal — working in exactly the case nobody ships. Not from
    /// `settings.json` either: that file is plaintext on disk and is SHARED
    /// with the installed Release build.
    ///
    /// `KeychainAuth` is the precedent for reading a secret in this app; this
    /// item is written by the Settings field in Task 3 and read here.
    private static func sharedSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty
        else { return nil }
        return secret
    }

    /// Composes the full snapshot. Reading every property here is what arms
    /// the observation above — a field read only inside `publish()` would not
    /// trigger a re-publish when it changed.
    private func snapshot() -> RosterSnapshot? {
        guard let machineId = MachineIdentity.stableId() else { return nil }
        let indexes = RosterSnapshot.paneIndexes(in: store.panes)
        let now = Int(Date().timeIntervalSince1970)
        var rows: [RosterSnapshot.Pane] = []
        for session in store.openSessions {
            guard let paneIndex = indexes[session.id] else { continue }
            let activity = SessionActivity.of(
                session, isUnread: store.unreadSessionIds.contains(session.id))
            let wire = RosterSnapshot.wireState(for: activity)
            if lastStates[session.id] != wire {
                lastStates[session.id] = wire
                stateSince[session.id] = now
            }
            rows.append(RosterSnapshot.Pane(
                sessionId: session.id.uuidString,
                paneIndex: paneIndex,
                title: session.title,
                project: session.projectLabel,
                state: wire,
                stateSince: stateSince[session.id] ?? now,
                contextPct: session.statusBar.contextPct,
                model: session.statusBar.model,
                messageCount: session.statusBar.messageCount))
        }
        let limits = SharedRateLimitData.shared
        return RosterSnapshot(
            machineId: machineId,
            displayName: MachineIdentity.resolvedDisplayName(
                setting: settings.machineDisplayName,
                fallback: MachineIdentity.defaultDisplayName()),
            publishedAt: now,
            sessionPct: limits.sessionPct,
            weeklyPct: limits.weeklyPct,
            panes: rows.sorted { $0.paneIndex < $1.paneIndex })
    }

    private func publish() {
        guard settings.rosterEnabled, let snapshot = snapshot() else { return }
        if task == nil { connectIfConfigured() }
        guard let task,
              let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                // Drop the socket so the next change reconnects. A send error
                // on a hibernated peer is routine, not a fault.
                self?.logger.notice("roster: send failed, will reconnect: \(error.localizedDescription, privacy: .public)")
                self?.task = nil
            }
        }
    }
}
