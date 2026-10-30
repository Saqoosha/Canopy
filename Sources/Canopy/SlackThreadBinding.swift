import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SlackThreadBinding")

/// The pane menu's Slack items: binds a daemon session to a Slack thread so
/// every reply there reaches the session. The daemon's `SlackBridge` carries the request
/// to the Worker; a mirror's request goes to the daemon on its own Mac, which runs the
/// session and its gate. Why: docs/superpowers/specs/2026-10-22-slack-thread-binding-design.md.
@MainActor
extension SessionStore {
    /// A session this Mac's daemon runs, or a mirror of one on another Mac: the gate and the
    /// bridge live with the daemon. A mirror only once attached, as for `canStop`.
    func canBindSlackThread(_ session: OpenSession) -> Bool {
        if session.origin.mirrorTarget != nil { return session.mirrorHostSessionId != nil }
        return session.isDaemonHosted && session.daemonKey != nil && daemonControl != nil
    }

    /// Where a session's Slack verbs go: this Mac's daemon, or the mirror's own Mac.
    private enum SlackRoute: Hashable {
        case local
        case peer(machineId: String)
    }

    private func slackRoute(_ session: OpenSession) -> SlackRoute {
        if let target = session.origin.mirrorTarget { return .peer(machineId: target.machineId) }
        return .local
    }

    /// The daemon's name for the session: a mirror's `key` is its own Mac's id for it.
    private static func slackRefParams(_ session: OpenSession) -> [String: Any] {
        guard session.origin.mirrorTarget != nil else { return daemonRefParams(session) }
        var params: [String: Any] = ["sessionId": session.resumeId]
        if let key = session.mirrorHostSessionId { params["key"] = key }
        return params
    }

    /// Sends a Slack verb along the route; the failure is a phrase for an alert.
    private func slackRequest(_ route: SlackRoute, _ verb: String, _ params: [String: Any]) async -> Result<[String: Any], SlackFailure> {
        switch route {
        case .local:
            guard let control = daemonControl else { return .failure(SlackFailure("this Mac's session service is not connected")) }
            return await control.request(verb, params).mapError { SlackFailure(Self.describe($0)) }
        case .peer(let machineId):
            let name = remoteRosters[machineId]?.displayName ?? machineId
            return await PeerControl.request(machineId: machineId, verb, params).mapError { SlackFailure($0.message(machineName: name)) }
        }
    }

    private struct SlackFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    func promptSlackThreadBinding(_ id: UUID) {
        guard let session = openSessions.first(where: { $0.id == id }), canBindSlackThread(session) else { return }
        let alert = NSAlert()
        alert.messageText = "Connect “\(session.title)” to a Slack thread"
        alert.informativeText = "Every reply in the thread reaches this session. Nothing is posted back. "
            + "Replies from other people run read-only; yours run like a prompt typed here."
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
        guard let session = openSessions.first(where: { $0.id == id }), canBindSlackThread(session) else { return }
        let route = slackRoute(session)
        var params = Self.slackRefParams(session)
        params["permalink"] = permalink
        params["ttlDays"] = ttlDays
        Task { [weak self] in
            guard let self else { return }
            switch await self.slackRequest(route, "slack_bind", params) {
            case .success:
                logger.notice("bound session \(id.uuidString, privacy: .public) to a Slack thread")
                await self.refreshSlackThreads()
            case .failure(let failure):
                Self.showSlackFailure("Could not connect to the Slack thread (\(failure.message)).")
            }
        }
    }

    /// Removes the bindings the Worker holds for this session.
    func unbindSlackThreads(_ id: UUID) {
        guard let session = openSessions.first(where: { $0.id == id }), canBindSlackThread(session) else { return }
        let route = slackRoute(session)
        let keys = Self.slackKeys(for: session)
        Task { [weak self] in
            guard let self else { return }
            let listed = await self.slackRequest(route, "slack_bindings", [:])
            guard case .success(let result) = listed else {
                if case .failure(let failure) = listed {
                    Self.showSlackFailure("Could not read the Slack connections (\(failure.message)).")
                }
                return
            }
            let items = (result["items"] as? [[String: Any]] ?? []).filter { keys.contains($0["sessionKey"] as? String ?? "") }
            for item in items {
                guard let channel = item["channel"] as? String, let threadTs = item["threadTs"] as? String else { continue }
                if case .failure(let failure) = await self.slackRequest(route, "slack_unbind", ["channel": channel, "threadTs": threadTs]) {
                    Self.showSlackFailure("Could not disconnect the Slack thread (\(failure.message)).")
                }
            }
            logger.notice("unbound \(items.count, privacy: .public) Slack thread(s) from \(id.uuidString, privacy: .public)")
            await self.refreshSlackThreads()
        }
    }

    /// The thread a session is bound to, if any.
    func slackThreads(for session: OpenSession) -> [URL] {
        Self.slackKeys(for: session).flatMap { slackThreadsBySessionKey[$0] ?? [] }
    }

    /// A binding names its session by resume id, or by daemon key if made before 3.16.6.
    private static func slackKeys(for session: OpenSession) -> [String] {
        [session.resumeId.lowercased(), session.resumeId, session.daemonKey, session.mirrorHostSessionId]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Re-reads the bindings now, then once a minute: a binding can also end on the Worker
    /// (expiry) or from another client, which the GUI hears about no other way.
    func startSlackThreadRefresh() {
        guard !slackThreadRefreshStarted else { return }
        slackThreadRefreshStarted = true
        Task { [weak self] in
            while let self {
                await self.refreshSlackThreads()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Reads this Mac's bindings and those of every Mac a mirror pane is attached to. A Mac
    /// whose bridge is off or unreachable contributes nothing: no chip rather than a stale one.
    func refreshSlackThreads() async {
        var routes: [SlackRoute] = []
        // At launch and after a reconnect the client is not ready yet, and a request then
        // fails at once; without this wait the chip stays missing until the next minute.
        if let control = daemonControl, await control.waitUntilReady() { routes.append(.local) }
        let peers = Set(openSessions.compactMap { $0.mirrorHostSessionId != nil ? $0.origin.mirrorTarget?.machineId : nil })
        routes += peers.sorted().map { .peer(machineId: $0) }
        // Concurrently, so one unreachable peer does not hold back every other chip.
        let lookups = routes.map { route in Task { await self.slackThreadItems(route) } }
        var threads: [String: [URL]] = [:]
        for lookup in lookups {
            // A binding made before the Worker recorded its Mac is listed to every Mac.
            for item in await lookup.value where !(threads[item.key]?.contains(item.url) ?? false) {
                threads[item.key, default: []].append(item.url)
            }
        }
        if threads != slackThreadsBySessionKey { slackThreadsBySessionKey = threads }
    }

    private struct SlackThreadItem: Sendable {
        let key: String
        let url: URL
    }

    /// One route's bindings, or none when it fails.
    private func slackThreadItems(_ route: SlackRoute) async -> [SlackThreadItem] {
        guard case .success(let result) = await slackRequest(route, "slack_bindings", [:]) else { return [] }
        var items: [SlackThreadItem] = []
        for item in result["items"] as? [[String: Any]] ?? [] {
            guard let key = item["sessionKey"] as? String, let url = Self.slackThreadURL(item) else { continue }
            items.append(SlackThreadItem(key: key, url: url))
        }
        return items
    }

    /// `slack.com/archives/<channel>/p<ts without the dot>` redirects to the signed-in workspace.
    nonisolated static func slackThreadURL(_ item: [String: Any]) -> URL? {
        guard let channel = item["channel"] as? String, let threadTs = item["threadTs"] as? String else { return nil }
        return URL(string: "https://slack.com/archives/\(channel)/p\(threadTs.replacingOccurrences(of: ".", with: ""))")
    }

    /// The user just asked for this, so the failure is shown at once rather than in the
    /// launcher's failure banner, which a bind from the pane menu never looks at.
    private static func showSlackFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Slack"
        alert.informativeText = message
        alert.runModal()
    }

    private nonisolated static func describe(_ failure: ControlClient.Failure) -> String {
        switch failure {
        case .refused(let message): return message
        case .disconnected: return "the session service is not connected"
        case .timedOut: return "the session service did not answer"
        }
    }
}
