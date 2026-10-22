import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SlackThreadBinding")

/// The pane menu's "Connect to Slack thread…": binds a daemon session to a Slack thread so
/// people there can ask it read-only questions. The daemon's `SlackBridge` carries the request
/// to the Worker. Why: docs/superpowers/specs/2026-10-22-slack-thread-binding-design.md.
@MainActor
extension SessionStore {
    /// Only a session this Mac's daemon runs: the gate and the bridge live there.
    func canBindSlackThread(_ session: OpenSession) -> Bool {
        session.isDaemonHosted && session.daemonKey != nil && daemonControl != nil
    }

    func promptSlackThreadBinding(_ id: UUID) {
        guard let session = openSessions.first(where: { $0.id == id }), canBindSlackThread(session) else { return }
        let alert = NSAlert()
        alert.messageText = "Connect “\(session.title)” to a Slack thread"
        alert.informativeText = "People in the thread can ask this session questions with @Saqoolaude. "
            + "It answers by reading only, and each answer reaches the thread after you approve it in Slack."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://….slack.com/archives/C…/p…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let permalink = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !permalink.isEmpty else { return }
        bindSlackThread(id, permalink: permalink)
    }

    func bindSlackThread(_ id: UUID, permalink: String, ttlDays: Int = 7) {
        guard let session = openSessions.first(where: { $0.id == id }), let control = daemonControl else { return }
        var params = Self.daemonRefParams(session)
        params["permalink"] = permalink
        params["ttlDays"] = ttlDays
        Task { [weak self] in
            switch await control.request("slack_bind", params) {
            case .success:
                logger.notice("bound session \(id.uuidString, privacy: .public) to a Slack thread")
            case .failure(let failure):
                self?.noteSessionFailure(title: session.title,
                                         message: "Could not connect to the Slack thread (\(Self.describe(failure))).", status: -2)
            }
        }
    }

    /// Removes every binding the Worker holds for this session.
    func unbindSlackThreads(_ id: UUID) {
        guard let session = openSessions.first(where: { $0.id == id }), let control = daemonControl,
              let key = session.daemonKey else { return }
        Task { [weak self] in
            let listed = await control.request("slack_bindings", [:])
            guard case .success(let result) = listed else {
                if case .failure(let failure) = listed {
                    self?.noteSessionFailure(title: session.title,
                                             message: "Could not read the Slack connections (\(Self.describe(failure))).", status: -2)
                }
                return
            }
            let items = (result["items"] as? [[String: Any]] ?? []).filter { $0["sessionKey"] as? String == key }
            for item in items {
                guard let channel = item["channel"] as? String, let threadTs = item["threadTs"] as? String else { continue }
                if case .failure(let failure) = await control.request("slack_unbind", ["channel": channel, "threadTs": threadTs]) {
                    self?.noteSessionFailure(title: session.title,
                                             message: "Could not disconnect the Slack thread (\(Self.describe(failure))).", status: -2)
                }
            }
            logger.notice("unbound \(items.count, privacy: .public) Slack thread(s) from \(id.uuidString, privacy: .public)")
        }
    }

    private nonisolated static func describe(_ failure: ControlClient.Failure) -> String {
        switch failure {
        case .refused(let message): return message
        case .disconnected: return "the session service is not connected"
        case .timedOut: return "the session service did not answer"
        }
    }
}
