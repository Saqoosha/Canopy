import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlSession")

/// One client's control connection to the daemon, after `hello`.
/// Requests are answered one `response` per id; `subscribe` adds
/// `session_state` pushes when a row changes.
@MainActor
final class ControlSession {
    private let store: SessionStore
    private let send: ([String: Any]) -> Void
    private let allowBypass: () -> Bool
    /// On this Mac's local socket (the GUI), not a TCP client with the mirror password.
    private let isLocal: Bool
    private var subscribed = false
    private var lastPushed: [ControlProtocol.SessionRow]?
    private var lastUpgradeState: UpgradeState?
    private var recheck: Timer?
    private var stopped = false
    /// Open `listen` requests on this connection, by request id.
    private var listens: [String: (waiter: UUID, cursor: ControlEventCursor)] = [:]

    /// `ShimProcess` is not `@Observable`, so a client attaching or a shim
    /// dying changes a row without waking the observation tracker. This
    /// re-reads the rows on a timer and pushes only when they differ.
    static let recheckInterval: TimeInterval = 5

    init(store: SessionStore, isLocal: Bool, allowBypass: @escaping () -> Bool,
         send: @escaping ([String: Any]) -> Void) {
        self.store = store
        self.isLocal = isLocal
        self.allowBypass = allowBypass
        self.send = send
        // Sessions opened or closed from now on are recorded for `listen`, connected or not.
        ControlEventLog.shared.track(store)
    }

    func stop() {
        stopped = true
        recheck?.invalidate()
        recheck = nil
        for id in Array(listens.keys) { endListen(id) }
    }

    func handle(_ dict: [String: Any]) {
        guard !stopped else { return }
        guard let request = ControlProtocol.parseRequest(dict) else {
            logger.error("control: unreadable request (type=\(dict["type"] as? String ?? "nil", privacy: .public))")
            return
        }
        switch request.verb {
        case "list_sessions": listSessions(request)
        case "list_folders": listFolders(request)
        case "browse_dir": browse(request)
        case "mkdir": makeFolder(request)
        case "open_session": openSession(request)
        case "stop_session": stopSession(request)
        case "subscribe": subscribe(request)
        case "rename_session": renameSession(request)
        case "restart_session": restartSession(request)
        case "switch_account": switchAccount(request)
        case "list_accounts": listAccounts(request)
        case "request_recap": requestRecap(request)
        case "roster_secret_changed":
            // The GUI wrote a new relay secret to the Keychain; reconnect with it. Only this
            // Mac's GUI writes that Keychain item, so a TCP client has no business asking.
            guard isLocal else { return fail(request, "local clients only") }
            guard let publisher = RosterPublisher.current else { return fail(request, "no roster publisher in the daemon") }
            publisher.secretChanged()
            reply(request, ["ok": true])
        case "restart_now":
            // Interrupts every running turn on this Mac; only this Mac's GUI may ask.
            guard isLocal else { return fail(request, "local clients only") }
            guard let restart = DaemonUpgradeCenter.shared.restartNow else { return fail(request, "not the session service") }
            if let refusal = restart() { return fail(request, refusal) }
            reply(request, ["ok": true])
        case "mirror_status": reply(request, ["status": MirrorServerStatus.shared.state.wire])
        case "send_message": sendMessage(request)
        case "session_status": sessionStatus(request)
        case "latest_reply": latestReply(request)
        case "wait_turn": waitTurn(request)
        case "pending_requests": pendingRequests(request)
        case "listen": listen(request)
        default: fail(request, "unknown verb")
        }
    }

    // MARK: - Verbs

    private func sendMessage(_ request: ControlProtocol.Request) {
        switch ControlProtocol.parseSendMessage(request.params) {
        case .failure(let error):
            fail(request, error.message)
        case .success(let message):
            guard let session = requestedSession(request) else { return }
            let replyId = UUID().uuidString.lowercased()
            guard let shim = session.shim else {
                reply(request, ControlProtocol.replyWire(Self.notRunningRefusal, replyId: replyId))
                return
            }
            // No-op when a client already holds a channel; opens one when the session has none.
            shim.launchHeadlessChannel()
            shim.noteControlReply(replyId)
            let disposition = shim.submitPhoneReply(text: message.text, replyId: replyId)
            if case .refused = disposition {
                shim.forgetControlReply(replyId)
            }
            reply(request, ControlProtocol.replyWire(disposition, replyId: replyId))
        }
    }

    private func sessionStatus(_ request: ControlProtocol.Request) {
        replyTurn(request, includeText: false)
    }

    private func latestReply(_ request: ControlProtocol.Request) {
        replyTurn(request, includeText: true)
    }

    private func replyTurn(_ request: ControlProtocol.Request, includeText: Bool) {
        let query = ControlProtocol.parseSessionQuery(request.params)
        guard let session = requestedSession(request) else { return }
        guard let shim = session.shim else { fail(request, "not running"); return }
        guard let snap = shim.controlTurnSnapshot(replyId: query.replyId) else {
            fail(request, "unknown reply id")
            return
        }
        reply(request, ControlProtocol.statusWire(
            state: snap.state, replyId: snap.replyId,
            text: includeText ? snap.text : nil, turnDone: snap.turnDone))
    }

    /// `wait_turn` must not block `handle()` — the socket read loop is stuck
    /// until it returns. A later `reply` from the main queue is the shape the
    /// connection already uses. The poll is bounded (0.5 s × 120) so a turn
    /// that never finishes still answers.
    private func waitTurn(_ request: ControlProtocol.Request) {
        let query = ControlProtocol.parseSessionQuery(request.params)
        guard let session = requestedSession(request) else { return }
        guard session.shim != nil else { fail(request, "not running"); return }
        pollTurn(request, session: session, replyId: query.replyId, remaining: 120)
    }

    private static var notRunningRefusal: ShimProcess.PhoneReplyDisposition {
        let dead = ShimProcess.phoneReplyBlockingReason(shimIsLive: false, permissionOutstanding: false, awaitingAnswer: false)!
        return .refused(dead.reason, code: dead.code)
    }

    private func pendingRequests(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        reply(request, ["requests": session.shim?.pendingRequestsWire() ?? []])
    }

    private func pollTurn(_ request: ControlProtocol.Request, session: OpenSession, replyId: String?, remaining: Int) {
        guard let shim = session.shim else { fail(request, "not running"); return }
        guard let snap = shim.controlTurnSnapshot(replyId: replyId) else {
            fail(request, "unknown reply id")
            return
        }
        let matched = snap.turnDone
        if matched || remaining <= 0 {
            reply(request, ControlProtocol.statusWire(
                state: snap.state, replyId: snap.replyId, text: snap.text, turnDone: snap.turnDone))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.pollTurn(request, session: session, replyId: replyId, remaining: remaining - 1)
            }
        }
    }

    /// Answers with the first matching event after `since`, or waits for one.
    /// Like `wait_turn` it never blocks `handle()`: the request parks a waiter
    /// on the log and is answered from whichever append matches, or by its timeout.
    private func listen(_ request: ControlProtocol.Request) {
        let params: ControlListenParams
        switch ControlListenParams.parse(request.params) {
        case .success(let parsed): params = parsed
        case .failure(let error): return fail(request, error.message)
        }
        guard listens[request.id] == nil else { return fail(request, "a listen with this id is already open") }
        let log = ControlEventLog.shared
        let start: ControlEventCursor
        switch log.scan(since: params.since, filter: params.filter) {
        case .event(let event, let next): return replyEvent(request, event, cursor: next)
        case .wait(let next): start = next
        }
        let id = request.id
        let filter = params.filter
        let waiter = log.addWaiter { [weak self] in
            guard let self, let cursor = self.listens[id]?.cursor else { return }
            switch log.scan(since: cursor, filter: filter) {
            case .event(let event, let next):
                self.endListen(id)
                self.replyEvent(request, event, cursor: next)
            case .wait(let next):
                self.listens[id]?.cursor = next
            }
        }
        listens[id] = (waiter, start)
        DispatchQueue.main.asyncAfter(deadline: .now() + params.timeout) { [weak self] in
            MainActor.assumeIsolated {
                // The waiter id tells this listen apart from a later one reusing the request id.
                guard let self, let entry = self.listens[id], entry.waiter == waiter else { return }
                self.endListen(id)
                self.reply(request, ["timedOut": true, "cursor": entry.cursor.wire])
            }
        }
    }

    private func replyEvent(_ request: ControlProtocol.Request, _ event: ControlEvent, cursor: ControlEventCursor) {
        reply(request, ["event": event.wire, "cursor": cursor.wire])
    }

    private func endListen(_ id: String) {
        guard let entry = listens.removeValue(forKey: id) else { return }
        ControlEventLog.shared.removeWaiter(entry.waiter)
    }

    private func listSessions(_ request: ControlProtocol.Request) {
        let limit = ControlProtocol.limit(request.params, default: 50)
        switch request.params["scope"] as? String ?? "open" {
        case "open":
            reply(request, ["sessions": openRows().prefix(limit).map(\.wire)])
        case "recent":
            Task { @MainActor in
                let query = (request.params["query"] as? String ?? "").lowercased()
                // Answer from the list the daemon holds; the rescan an unfiltered ask starts
                // serves the next one. A search never starts one: that would be one per keystroke.
                if store.recents.isEmpty {
                    await Self.refreshRecents(store).value
                } else if query.isEmpty {
                    _ = Self.refreshRecents(store)
                }
                guard !stopped else { return }
                let open = Set(store.openSessions.map(\.resumeId))
                let rows = store.recents
                    .filter { $0.canOpen && !open.contains($0.id) && !store.hiddenIds.contains($0.id) }
                    .filter { query.isEmpty || $0.title.lowercased().contains(query) || $0.projectName.lowercased().contains(query) }
                    .prefix(limit)
                    .map { ControlProtocol.SessionRow(
                        key: nil, resumeId: $0.id, title: $0.title, project: $0.projectName,
                        cwd: $0.projectDirectory.path, state: "closed", running: false, clients: 0,
                        lastActiveAt: $0.timestamp.timeIntervalSince1970, model: "", messageCount: 0,
                        permissionMode: "", accountId: nil).wire }
                reply(request, ["sessions": Array(rows)])
            }
        default:
            fail(request, "unknown scope")
        }
    }

    /// One rescan at a time across every control connection; asks during one share it.
    private static var recentsRefresh: Task<Void, Never>?

    private static func refreshRecents(_ store: SessionStore) -> Task<Void, Never> {
        if let running = recentsRefresh { return running }
        let task = Task { @MainActor in
            // Nothing in the daemon reads the search index, and it is every transcript on the Mac.
            await store.refreshRecents(warmSearchIndex: false)
            recentsRefresh = nil
        }
        recentsRefresh = task
        return task
    }

    private func listFolders(_ request: ControlProtocol.Request) {
        let limit = ControlProtocol.limit(request.params, default: 20)
        let folders = RecentDirectories.load().filter { FileManager.default.fileExists(atPath: $0.path) }
        reply(request, ["folders": folders.prefix(limit).map(\.path)])
    }

    private func browse(_ request: ControlProtocol.Request) {
        let path = request.params["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        switch ControlProtocol.listDirectory(path: path, showHidden: request.params["showHidden"] as? Bool == true) {
        case .success(let entries): reply(request, ["path": path, "entries": entries.map(\.wire)])
        case .failure(let error): fail(request, error.message)
        }
    }

    private func makeFolder(_ request: ControlProtocol.Request) {
        guard let parent = request.params["parent"] as? String, let name = request.params["name"] as? String else {
            fail(request, "parent and name are required")
            return
        }
        switch ControlProtocol.mkdir(parent: parent, name: name) {
        case .success(let path): reply(request, ["path": path])
        case .failure(let error): fail(request, error.message)
        }
    }

    private func openSession(_ request: ControlProtocol.Request) {
        let params: ControlProtocol.OpenParams
        switch ControlProtocol.parseOpenParams(request.params, allowBypass: allowBypass()) {
        case .success(let parsed): params = parsed
        case .failure(let error):
            fail(request, error.message)
            return
        }
        var directory = URL(fileURLWithPath: params.cwd, isDirectory: true)
        if let branch = params.worktreeBranch {
            do {
                directory = try GitWorktree.createWorktree(repo: directory, branch: branch,
                                                           baseRef: GitWorktree.defaultBaseRef(for: directory))
            } catch {
                logger.error("control open_session: worktree failed: \(error.localizedDescription, privacy: .public)")
                fail(request, "worktree failed: \(error.localizedDescription)")
                return
            }
        }
        // A placeholder the CLI's id replaces once a turn has run; follow-ups should use `key`.
        let sessionId = UUID().uuidString.lowercased()
        let options = SessionStore.HeadlessOptions(model: params.model, effort: params.effort,
                                                   permissionMode: params.permissionMode,
                                                   initialPrompt: params.initialPrompt)
        guard let shim = store.startHeadlessSession(directory: directory, resumeId: sessionId, isExistingTranscript: false,
                                                    title: nil, options: options),
              let session = shim.boundSession else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        // The prompt is stored on the session; nothing sends it until a
        // `launch_claude` assigns a channel. A control open has no webview.
        var result: [String: Any] = ["sessionId": sessionId, "key": session.id.uuidString, "cwd": directory.path]
        if session.pendingInitialPrompt != nil {
            let replyId = UUID().uuidString.lowercased()
            session.pendingInitialPromptReplyId = replyId
            result["replyId"] = replyId
            shim.launchHeadlessChannel()
        }
        reply(request, result)
    }

    private func stopSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        store.closeSession(session.id, keepingFailure: false, mirrorEndReason: MirrorOpenRequest.stoppedByClient)
        reply(request, ["ok": true])
    }

    /// The open session a request names, or nil after answering the request with the reason.
    private func requestedSession(_ request: ControlProtocol.Request) -> OpenSession? {
        let refs = ControlProtocol.sessionRefs(request.params)
        guard !refs.isEmpty else {
            fail(request, "key or sessionId is required")
            return nil
        }
        guard let session = store.openSession(for: refs) else {
            fail(request, "no such session")
            return nil
        }
        return session
    }

    private func renameSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        guard let title = request.params["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(request, "title is required")
            return
        }
        store.commitRename(SessionStore.RenameTarget(sessionId: session.resumeId, openSessionId: session.id,
                                                     currentTitle: session.title), to: title)
        reply(request, ["ok": true])
    }

    /// The daemon has no pane to remount, so after `restartSession` parks the
    /// row it starts the shim again itself.
    private func restartSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        store.restartSession(session.id)
        let started = store.startHeadlessSession(resumeId: session.resumeId) != nil
        // Without this the footer keeps listing the session as on an older extension until the next minute's check.
        DaemonUpgradeCenter.shared.refreshExtensionState?()
        guard started else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["ok": true])
    }

    private func switchAccount(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        let accountId = ControlProtocol.accountId(request.params)
        let account = accountId.flatMap { ClaudeAccountStore.account(id: $0) }
        if accountId != nil, account == nil {
            fail(request, "no such account")
            return
        }
        store.switchAccount(session.id, to: account)
        // Same account: nothing was stopped. Another: `restartSession` parked the row.
        let failed = session.shim == nil && store.startHeadlessSession(resumeId: session.resumeId) == nil
        DaemonUpgradeCenter.shared.refreshExtensionState?()
        if failed {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["ok": true])
    }

    /// A client that came back after being away asks for the session's recap.
    private func requestRecap(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        guard let shim = session.shim else {
            reply(request, ["requested": false, "reason": "not running"])
            return
        }
        if let reason = shim.recapIneligibilityReason {
            reply(request, ["requested": false, "reason": reason])
            return
        }
        guard shim.requestRecap() else {
            reply(request, ["requested": false, "reason": "not eligible"])
            return
        }
        reply(request, ["requested": true])
    }

    private func listAccounts(_ request: ControlProtocol.Request) {
        let accounts = ClaudeAccountStore.load().map { ["id": $0.id, "name": $0.name] }
        reply(request, ["accounts": accounts, "defaultId": ClaudeAccountStore.defaultAccountId()])
    }

    // MARK: - subscribe

    private func subscribe(_ request: ControlProtocol.Request) {
        reply(request, ["ok": true])
        guard !subscribed else { return }
        subscribed = true
        trackOpenSessions()
        if isLocal { trackUpgradeState() }  // only this Mac's GUI shows it
        recheck = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushIfChanged(self?.openRows() ?? []) }
        }
    }

    private func openRows() -> [ControlProtocol.SessionRow] {
        store.openSessions.map { session in
            let activity = SessionActivity.of(session, isUnread: store.unreadSessionIds.contains(session.id))
            return ControlProtocol.SessionRow(
                key: session.id.uuidString, resumeId: session.resumeId, title: session.title,
                project: session.project, cwd: session.origin.workingDirectory.path,
                state: RosterSnapshot.wireState(for: activity), running: session.shim?.isLive == true,
                clients: session.shim?.mirrorCount ?? 0, lastActiveAt: session.lastActiveAt.timeIntervalSince1970,
                model: session.statusBar.model, messageCount: session.statusBar.messageCount,
                permissionMode: session.permissionMode.rawValue, accountId: session.claudeAccount?.id)
        }
    }

    /// Re-armed from its own `onChange`, one tracker at a time, like
    /// `AppDelegate.trackMirrorSettings`.
    private func trackOpenSessions() {
        guard !stopped else { return }
        let rows = withObservationTracking {
            openRows()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackOpenSessions() } }
        }
        pushIfChanged(rows)
    }

    /// Re-armed from its own `onChange`, like `trackOpenSessions`.
    private func trackUpgradeState() {
        guard !stopped else { return }
        let state = withObservationTracking {
            DaemonUpgradeCenter.shared.state
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackUpgradeState() } }
        }
        guard let state, state != lastUpgradeState else { return }
        lastUpgradeState = state
        send(["type": DaemonUpgrade.stateFrameType, "state": state.wire])
    }

    private func pushIfChanged(_ rows: [ControlProtocol.SessionRow]) {
        guard !stopped, rows != lastPushed else { return }
        lastPushed = rows
        send(["type": "session_state", "sessions": rows.map(\.wire)])
    }

    // MARK: - Replies

    private func reply(_ request: ControlProtocol.Request, _ result: [String: Any]) {
        guard !stopped else { return }
        send(ControlProtocol.response(id: request.id, result: result))
    }

    private func fail(_ request: ControlProtocol.Request, _ message: String) {
        guard !stopped else { return }
        logger.notice("control \(request.verb, privacy: .public) refused: \(message, privacy: .public)")
        send(ControlProtocol.errorResponse(id: request.id, message: message))
    }
}
