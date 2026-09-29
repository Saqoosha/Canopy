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
    private var subscribed = false
    private var lastPushed: [ControlProtocol.SessionRow]?
    private var recheck: Timer?
    private var stopped = false

    /// `ShimProcess` is not `@Observable`, so a client attaching or a shim
    /// dying changes a row without waking the observation tracker. This
    /// re-reads the rows on a timer and pushes only when they differ.
    static let recheckInterval: TimeInterval = 5

    init(store: SessionStore, allowBypass: @escaping () -> Bool, send: @escaping ([String: Any]) -> Void) {
        self.store = store
        self.allowBypass = allowBypass
        self.send = send
    }

    func stop() {
        stopped = true
        recheck?.invalidate()
        recheck = nil
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
            // The GUI wrote a new relay secret to the Keychain; reconnect with it.
            RosterPublisher.current?.secretChanged()
            reply(request, ["ok": true])
        default: fail(request, "unknown verb")
        }
    }

    // MARK: - Verbs

    private func listSessions(_ request: ControlProtocol.Request) {
        let limit = ControlProtocol.limit(request.params, default: 50)
        switch request.params["scope"] as? String ?? "open" {
        case "open":
            reply(request, ["sessions": openRows().prefix(limit).map(\.wire)])
        case "recent":
            Task { @MainActor in
                await store.refreshRecents()
                guard !stopped else { return }
                let open = Set(store.openSessions.map(\.resumeId))
                let query = (request.params["query"] as? String ?? "").lowercased()
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
        // A placeholder the CLI's own id replaces once a client's webview
        // launches it; the client attaches with this id right away.
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
        reply(request, ["sessionId": sessionId, "key": session.id.uuidString, "cwd": directory.path])
    }

    private func stopSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        store.closeSession(session.id, keepingFailure: false)
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
        guard store.startHeadlessSession(resumeId: session.resumeId) != nil else {
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
        if session.shim == nil, store.startHeadlessSession(resumeId: session.resumeId) == nil {
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
