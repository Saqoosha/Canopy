import Foundation

/// The Canopy Server control connection's wire shapes. No daemon, socket or
/// shim needed, so the probe reaches every rule.
///
/// A control connection is a `MirrorServer` connection whose first line is
/// `hello`. After `hello_ok`, the client sends `request` lines and gets one
/// `response` per id; after `subscribe` the server also pushes
/// `session_state` lines. `send_message` delivers a user turn through the
/// same queue the phone uses. See docs/superpowers/specs/2026-09-29-canopy-server-design.md.
enum ControlProtocol {
    static let version = 1
    static let helloType = "hello"

    struct ControlError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    enum HelloCheck: Equatable {
        case ok
        case unauthorized
        case versionMismatch(client: Int, server: Int)
    }

    /// A local (Unix socket) peer is trusted by file permission; a TCP peer
    /// must present the mirror password. A TCP peer is refused when no
    /// password is configured at all, rather than let in.
    static func checkHello(_ dict: [String: Any], trustsPeer: Bool, expectedToken: String?) -> HelloCheck {
        if !trustsPeer {
            guard let provided = dict["token"] as? String, let expectedToken,
                  MirrorAccess.tokensMatch(provided, expectedToken) else { return .unauthorized }
        }
        // Absent means a client older than the field, which is not this version.
        let client = dict["protocolVersion"] as? Int ?? 0
        return client == version ? .ok : .versionMismatch(client: client, server: version)
    }

    struct Request {
        let id: String
        let verb: String
        let params: [String: Any]
    }

    static func parseRequest(_ dict: [String: Any]) -> Request? {
        guard dict["type"] as? String == "request",
              let id = dict["id"] as? String, !id.isEmpty,
              let verb = dict["verb"] as? String, !verb.isEmpty else { return nil }
        return Request(id: id, verb: verb, params: dict["params"] as? [String: Any] ?? [:])
    }

    /// A request's `limit`, never negative: `Array.prefix` traps on one, and
    /// that trap would take the whole daemon and every session down with it.
    static func limit(_ params: [String: Any], default fallback: Int) -> Int {
        max(0, params["limit"] as? Int ?? fallback)
    }

    static func response(id: String, result: Any) -> [String: Any] {
        ["type": "response", "id": id, "result": result]
    }

    static func errorResponse(id: String, message: String) -> [String: Any] {
        ["type": "response", "id": id, "error": message]
    }

    struct DirEntry: Equatable {
        let name: String
        let isDirectory: Bool
        var wire: [String: Any] { ["name": name, "isDirectory": isDirectory] }
    }

    /// Folders first, then files, each case-insensitively by name.
    static func listDirectory(path: String, showHidden: Bool) -> Result<[DirEntry], ControlError> {
        guard path.hasPrefix("/") else { return .failure(ControlError("path must be absolute")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(ControlError("not a folder"))
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            return .failure(ControlError("cannot read folder"))
        }
        let entries = children.compactMap { child -> DirEntry? in
            let name = child.lastPathComponent
            if !showHidden, name.hasPrefix(".") { return nil }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return DirEntry(name: name, isDirectory: isDir)
        }
        return .success(entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    /// Creates one folder. No `-p`: an existing folder is reported, the way
    /// `RemoteDirectoryBrowser`'s New Folder does. A peer Mac's browser shows
    /// these messages verbatim; Canopy Mobile matches "already exists" and
    /// "permission denied" as substrings.
    static func mkdir(parent: String, name: String) -> Result<String, ControlError> {
        guard parent.hasPrefix("/") else { return .failure(ControlError("path must be absolute")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(ControlError("not a folder"))
        }
        let trimmed = RemoteDirectoryRules.trimmedName(name)
        if let problem = RemoteDirectoryRules.newFolderNameProblem(trimmed) { return .failure(ControlError(problem)) }
        let path = RemoteDirectoryRules.childPath(of: parent, name: trimmed)
        if FileManager.default.fileExists(atPath: path) { return .failure(ControlError("already exists")) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            return .failure(ControlError(isWriteDenied(error as NSError) ? "permission denied" : "cannot create folder"))
        }
        return .success(path)
    }

    /// FileManager wraps POSIX `EACCES` in `NSCocoaErrorDomain` 513. Walk
    /// `NSUnderlyingErrorKey` so either spelling counts.
    private static func isWriteDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isWriteDenied(underlying) }
        return false
    }

    struct OpenParams: Equatable {
        let cwd: String
        let model: String?
        let effort: String?
        let permissionMode: PermissionMode?
        let worktreeBranch: String?
        let initialPrompt: String?
    }

    /// `allowBypass` is this Mac's `allowDangerouslySkipPermissions` opt-in:
    /// a remote client must not get a mode the Mac's own UI refuses.
    static func parseOpenParams(_ params: [String: Any], allowBypass: Bool) -> Result<OpenParams, ControlError> {
        guard let cwd = params["cwd"] as? String, cwd.hasPrefix("/") else {
            return .failure(ControlError("cwd must be absolute"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(ControlError("not a folder"))
        }
        var mode: PermissionMode?
        if let raw = params["permissionMode"] as? String {
            guard let parsed = PermissionMode(rawValue: raw) else { return .failure(ControlError("unknown permission mode")) }
            if parsed == .bypassPermissions, !allowBypass {
                return .failure(ControlError("bypass permissions is off on this Mac"))
            }
            mode = parsed
        }
        func nonEmpty(_ key: String) -> String? {
            (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return .success(OpenParams(cwd: cwd, model: nonEmpty("model"), effort: nonEmpty("effort"),
                                   permissionMode: mode, worktreeBranch: nonEmpty("worktreeBranch"),
                                   initialPrompt: nonEmpty("initialPrompt")))
    }

    enum SessionRef: Equatable {
        case key(String)
        case resumeId(String)
    }

    /// The ways a request names a session, tried in order: `key` (the daemon's
    /// `OpenSession.id`, which survives the CLI replacing a placeholder
    /// `resumeId`) and then `sessionId`, which still finds a session when the
    /// key is from a daemon that has since restarted.
    static func sessionRefs(_ params: [String: Any]) -> [SessionRef] {
        var refs: [SessionRef] = []
        if let key = params["key"] as? String, !key.isEmpty { refs.append(.key(key)) }
        if let id = params["sessionId"] as? String, !id.isEmpty { refs.append(.resumeId(id)) }
        return refs
    }

    /// `switch_account`'s target; nil, absent or "" (what `list_accounts` reports
    /// when no default is set) all mean the default login.
    static func accountId(_ params: [String: Any]) -> String? {
        (params["accountId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One session as `list_sessions` and `session_state` send it. `key` is the
    /// daemon's `OpenSession.id`: it survives the CLI replacing a placeholder
    /// `resumeId`, and exists only while the session is open.
    struct SessionRow: Equatable {
        let key: String?
        let resumeId: String
        let title: String
        let project: String
        let cwd: String
        let state: String
        let running: Bool
        let clients: Int
        let lastActiveAt: Double
        let model: String
        let messageCount: Int
        let permissionMode: String
        let accountId: String?

        var wire: [String: Any] {
            var dict: [String: Any] = [
                "resumeId": resumeId, "title": title, "project": project, "cwd": cwd, "state": state,
                "running": running, "clients": clients, "lastActiveAt": lastActiveAt,
                "model": model, "messageCount": messageCount, "permissionMode": permissionMode,
            ]
            if let key { dict["key"] = key }
            if let accountId { dict["accountId"] = accountId }
            return dict
        }

        init(key: String?, resumeId: String, title: String, project: String, cwd: String, state: String,
             running: Bool, clients: Int, lastActiveAt: Double, model: String, messageCount: Int,
             permissionMode: String, accountId: String?) {
            self.key = key
            self.resumeId = resumeId
            self.title = title
            self.project = project
            self.cwd = cwd
            self.state = state
            self.running = running
            self.clients = clients
            self.lastActiveAt = lastActiveAt
            self.model = model
            self.messageCount = messageCount
            self.permissionMode = permissionMode
            self.accountId = accountId
        }

        init?(wire: [String: Any]) {
            guard let resumeId = wire["resumeId"] as? String, !resumeId.isEmpty else { return nil }
            self.init(key: wire["key"] as? String, resumeId: resumeId,
                      title: wire["title"] as? String ?? "", project: wire["project"] as? String ?? "",
                      cwd: wire["cwd"] as? String ?? "", state: wire["state"] as? String ?? "closed",
                      running: wire["running"] as? Bool ?? false, clients: wire["clients"] as? Int ?? 0,
                      lastActiveAt: (wire["lastActiveAt"] as? NSNumber)?.doubleValue ?? 0,
                      model: wire["model"] as? String ?? "", messageCount: wire["messageCount"] as? Int ?? 0,
                      permissionMode: wire["permissionMode"] as? String ?? "",
                      accountId: wire["accountId"] as? String)
        }
    }

    struct SendMessage: Equatable {
        var text: String
    }

    /// `send_message`: `text` is required (trimmed; blank is refused). A
    /// non-empty `attachments` array is refused — image upload is not this
    /// verb. An absent or empty array is fine.
    static func parseSendMessage(_ params: [String: Any]) -> Result<SendMessage, ControlError> {
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(ControlError("The message was empty")) }
        if let attachments = params["attachments"] as? [Any], !attachments.isEmpty {
            return .failure(ControlError("attachments are not supported"))
        }
        return .success(SendMessage(text: text))
    }

    static func replyWire(_ disposition: ShimProcess.PhoneReplyDisposition, replyId: String) -> [String: Any] {
        switch disposition {
        case .injected:
            return ["ok": true, "disposition": "injected", "replyId": replyId]
        case .queued(let reason):
            var wire: [String: Any] = ["ok": true, "disposition": "queued", "replyId": replyId]
            if !reason.isEmpty { wire["reason"] = reason }
            return wire
        case .refused(let reason, let code):
            return [
                "ok": false,
                "disposition": "refused",
                "reason": reason,
                "reasonCode": code.rawValue,
                "replyId": replyId,
            ]
        }
    }

    /// `session_status` / `latest_reply` / `wait_turn` share one optional
    /// `replyId`. Absent or blank means "the control turn in flight, or the
    /// last one that finished".
    struct SessionQuery: Equatable {
        var replyId: String?
    }

    static func parseSessionQuery(_ params: [String: Any]) -> SessionQuery {
        let raw = (params["replyId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyId = (raw?.isEmpty == false) ? raw : nil
        return SessionQuery(replyId: replyId)
    }

    /// `state` is `idle` / `working` / `asking`. `turnDone` is true only after
    /// the control turn's `result` has been captured.
    static func statusWire(state: String, replyId: String?, text: String?, turnDone: Bool) -> [String: Any] {
        var wire: [String: Any] = ["ok": true, "state": state, "turnDone": turnDone]
        if let replyId, !replyId.isEmpty { wire["replyId"] = replyId }
        if let text { wire["text"] = text }
        return wire
    }
}
