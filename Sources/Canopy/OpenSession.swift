import Foundation
import Observation
import WebKit

/// One open session: live shim + webview, plus the metadata that the sidebar
/// row needs to render. Owned strongly by `SessionStore.openSessions`. When the
/// user closes a session (× button), the store drops the OpenSession; the
/// shim is stopped and the webview is released as a side effect.
///
/// "Open" is the user-visible state: the session row in the sidebar shows the
/// filled `desktopcomputer` icon and (on hover) the close button. A *closed*
/// session is not represented by an OpenSession at all — it's a `SessionEntry`
/// (local JSONL) or a `RemoteSession` (cloud) instead. See `SidebarRow`.
@Observable
final class OpenSession: Identifiable, Hashable {
    static func == (lhs: OpenSession, rhs: OpenSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum Origin: Hashable, Sendable {
        /// Started locally, working directory is on this Mac.
        case local(URL)
        /// SSH remote session targeting a directory on the remote host.
        case remote(host: String, path: URL)
        /// Teleported from a cloud session id; treated as `.local` after teleport
        /// completes, but the original cloud id is retained for de-duplication.
        case teleportedFrom(cloudSessionId: String, localPath: URL)

        var workingDirectory: URL {
            switch self {
            case .local(let url): url
            case .remote(_, let path): path
            case .teleportedFrom(_, let path): path
            }
        }

        var remoteHost: String? {
            if case .remote(let host, _) = self { return host }
            return nil
        }
    }

    enum Status: Equatable, Sendable {
        /// Shim is starting; show a spinner in the icon slot.
        case spawning
        /// Shim is up and the webview is mounted.
        case live
        /// Shim exited unexpectedly; user can click to retry.
        case crashed(exitCode: Int32)
    }

    let id: UUID
    var origin: Origin
    /// Claude Code session uuid used for `--resume` and JSONL filename.
    /// Always set; for a brand-new session this is the uuid the CLI assigns.
    var resumeId: String
    var title: String
    /// Project label shown as the row's secondary line. Usually the working
    /// directory's `lastPathComponent`, but a teleport may set it to the
    /// remote repo name (e.g. "owner/name") if the local cwd is ambiguous.
    var project: String
    var status: Status
    /// Updated whenever the user selects this row or sends a message. Drives
    /// the sidebar's "open block" sort order.
    var lastActiveAt: Date
    var statusBar: StatusBarData
    var connection: ConnectionState
    var permissionMode: PermissionMode
    var model: String?
    var effortLevel: String?
    var customApi: ModelProvider?
    /// True while Claude is generating a response (assistant / stream_event
    /// messages flowing). Updated by `ShimProcess.boundSession` mirror.
    /// Drives the animated flower icon in the sidebar.
    var isThinking: Bool = false

    /// True while a `tool_permission_request` is in flight — the extension
    /// asked the webview for tool approval and the user hasn't responded
    /// yet. Drives the "asking" icon in the sidebar (e.g. raised hand).
    var isAsking: Bool = false
    /// The shim subprocess. Strong reference; nil only between init and start.
    var shim: ShimProcess?
    /// The WKWebView mounted into the detail pane's ZStack. Strong reference;
    /// nil only between init and the first SessionContainer render.
    var webView: WKWebView?

    init(
        id: UUID = UUID(),
        origin: Origin,
        resumeId: String,
        title: String,
        project: String,
        status: Status = .spawning,
        lastActiveAt: Date = Date(),
        permissionMode: PermissionMode = .acceptEdits,
        model: String? = nil,
        effortLevel: String? = nil,
        customApi: ModelProvider? = nil
    ) {
        self.id = id
        self.origin = origin
        self.resumeId = resumeId
        self.title = title
        self.project = project
        self.status = status
        self.lastActiveAt = lastActiveAt
        self.statusBar = StatusBarData()
        self.connection = ConnectionState()
        self.permissionMode = permissionMode
        self.model = model
        self.effortLevel = effortLevel
        self.customApi = customApi
        self.statusBar.remoteHost = origin.remoteHost
    }

    /// True when this session was teleported from a cloud session — used by
    /// the sidebar to drop the matching cloud row.
    var teleportedFromCloudId: String? {
        if case .teleportedFrom(let cloudId, _) = origin { return cloudId }
        return nil
    }
}
