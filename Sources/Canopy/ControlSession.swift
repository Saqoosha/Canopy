import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlSession")

/// One client's control connection to the daemon, after `hello`.
/// Requests are answered one `response` per id; `subscribe` adds
/// `session_state` pushes whenever an open session's row changes.
@MainActor
final class ControlSession {
    private let store: SessionStore
    private let send: ([String: Any]) -> Void
    private var subscribed = false
    private var lastPushed: [[String: String]]?
    private var recheck: Timer?
    private var stopped = false

    /// `ShimProcess` is not `@Observable`, so a client attaching or a shim
    /// dying changes a row without waking the observation tracker. This
    /// re-reads the rows on a timer and pushes only when they differ.
    static let recheckInterval: TimeInterval = 5

    init(store: SessionStore, send: @escaping ([String: Any]) -> Void) {
        self.store = store
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
        default: fail(request, "unknown verb")
        }
    }

    // MARK: - Verbs

    private func listSessions(_ request: ControlProtocol.Request) {
        let limit = ControlProtocol.limit(request.params, default: 50)
        switch request.params["scope"] as? String ?? "open" {
        case "open":
            reply(request, ["sessions": Array(openRows().prefix(limit))])
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
                    .map { ["id": $0.id, "title": $0.title, "project": $0.projectName,
                            "cwd": $0.projectDirectory.path, "state": "closed", "running": false, "clients": 0,
                            "lastActiveAt": $0.timestamp.timeIntervalSince1970] as [String: Any] }
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
        switch ControlProtocol.parseOpenParams(request.params,
                                               allowBypass: CanopySettings.shared.allowDangerouslySkipPermissions) {
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
        guard store.startHeadlessSession(directory: directory, resumeId: sessionId, isExistingTranscript: false,
                                         title: nil, options: options) != nil else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["sessionId": sessionId, "cwd": directory.path])
    }

    private func stopSession(_ request: ControlProtocol.Request) {
        guard let sessionId = request.params["sessionId"] as? String,
              let session = store.openSessions.first(where: { $0.resumeId == sessionId }) else {
            fail(request, "no such session")
            return
        }
        store.closeSession(session.id, keepingFailure: false)
        reply(request, ["ok": true])
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

    private func openRows() -> [[String: Any]] {
        store.openSessions.map { session in
            let activity = SessionActivity.of(session, isUnread: store.unreadSessionIds.contains(session.id))
            return ["id": session.resumeId, "title": session.title, "project": session.project,
                    "cwd": session.origin.workingDirectory.path,
                    "state": RosterSnapshot.wireState(for: activity),
                    "running": session.shim?.isLive == true,
                    "clients": session.shim?.mirrorCount ?? 0,
                    "lastActiveAt": session.lastActiveAt.timeIntervalSince1970]
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

    private func pushIfChanged(_ rows: [[String: Any]]) {
        guard !stopped else { return }
        let signature = rows.map { row in
            ["id": row["id"] as? String ?? "", "title": row["title"] as? String ?? "",
             "state": row["state"] as? String ?? "", "clients": "\(row["clients"] as? Int ?? 0)",
             "running": "\(row["running"] as? Bool ?? false)"]
        }
        guard signature != lastPushed else { return }
        lastPushed = signature
        send(["type": "session_state", "sessions": rows])
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
