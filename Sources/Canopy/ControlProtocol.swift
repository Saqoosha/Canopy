import Foundation

/// The Canopy Server control connection's wire shapes. No daemon, socket or
/// shim needed, so the probe reaches every rule.
///
/// A control connection is a `MirrorServer` connection whose first line is
/// `hello`. After `hello_ok`, the client sends `request` lines and gets one
/// `response` per id; after `subscribe` the server also pushes
/// `session_state` lines. See docs/superpowers/specs/2026-09-29-canopy-server-design.md.
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
    /// `RemoteDirectoryBrowser`'s New Folder does.
    static func mkdir(parent: String, name: String) -> Result<String, ControlError> {
        let trimmed = RemoteDirectoryRules.trimmedName(name)
        if let problem = RemoteDirectoryRules.newFolderNameProblem(trimmed) { return .failure(ControlError(problem)) }
        let path = RemoteDirectoryRules.childPath(of: parent, name: trimmed)
        if FileManager.default.fileExists(atPath: path) { return .failure(ControlError("already exists")) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            return .failure(ControlError("cannot create folder"))
        }
        return .success(path)
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

    /// `key` (the daemon's `OpenSession.id`) outranks `sessionId` (a `resumeId`,
    /// which the CLI may already have replaced).
    static func sessionRef(_ params: [String: Any]) -> SessionRef? {
        if let key = params["key"] as? String, !key.isEmpty { return .key(key) }
        if let id = params["sessionId"] as? String, !id.isEmpty { return .resumeId(id) }
        return nil
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
}
