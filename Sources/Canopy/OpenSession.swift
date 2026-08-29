import Foundation
import Observation
import WebKit

/// One open session: live shim + webview — except while `.dormant`, which is
/// an open row with neither (see `Status`) — plus the metadata that the
/// sidebar row needs to render. Owned strongly by `SessionStore.openSessions`. When the
/// user closes a session (× button), the store drops the OpenSession; the
/// shim is stopped and the webview is released as a side effect.
///
/// "Open" is the user-visible state: the session row in the sidebar renders an
/// `ActivityDot` driven by `SessionActivity` and (on hover) the close button.
/// (`desktopcomputer` is the CLOSED-row icon; `Sidebar.iconView` routes every
/// open row to `ActivityDot` and marks the other branch unreachable.) A *closed*
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
        /// Shim is starting. Rendered as `SessionActivity.working` — the
        /// same breathing cyan as a session that is generating, because both
        /// mean "the machine is busy, not your turn".
        case spawning
        /// Shim is up and the webview is mounted.
        case live
        /// Shim exited unexpectedly. Note that this is effectively a
        /// transient state today: `Detail.swift`'s crash handler closes the
        /// session immediately, so the row disappears rather than offering a
        /// retry.
        case crashed(exitCode: Int32)
        /// Open row, no shim behind it — the state a launch-restored session
        /// starts in when no pane in the SANITIZED snapshot refers to it. That
        /// is wider than "no pane at quit": a pane lost to `paneCap`, or to the
        /// duplicate-resumeId rule, demotes its session here too.
        ///
        /// It exists because a `ShimProcess` is only ever created by
        /// `WebViewContainer`, which mounts only inside a pane. Restoring an
        /// unpaned session as `.spawning` would leave it there until a pane
        /// took it — arbitrarily long — and `SessionActivity` renders
        /// `.spawning` as the breathing cyan of a session that is working, so
        /// the row would read as busy with nothing running. `.dormant` falls
        /// through that ladder to `.idle` instead, which is what the row is.
        ///
        /// The state is erased by `SessionStore.startIfDormant(_:)` the
        /// moment a pane takes the session, so it is never seen by a mounted
        /// `SessionContainer`. What it costs versus a session that stayed
        /// open and RUNNING across the relaunch: no shim, so nothing resumes
        /// until a pane takes it. Note that is not the same as "until the row
        /// is clicked" — `closeSession` promotes the next open session when
        /// the closed one held the only pane, and Cmd+Shift+[/] and
        /// Cmd+Ctrl+1..9 assign a pane without a click on the row. A session
        /// that was ALREADY dormant at quit loses nothing here; it had no
        /// shim to lose. That is the deliberate trade — the alternative is
        /// spawning one Node subprocess per open session at launch.
        case dormant
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
    /// Feeds `SessionActivity.of`, which the sidebar dot and the MacroPad
    /// key both render from.
    var isThinking: Bool = false

    /// True while a `tool_permission_request` is in flight — the extension
    /// asked the webview for tool approval and the user hasn't responded
    /// yet. Feeds `SessionActivity.of` as the top non-error rung.
    var isAsking: Bool = false

    /// True when Claude is idle (no `stream_event`/`assistant` in flight)
    /// but at least one `run_in_background` task (Bash shell or Agent) is
    /// still running. Feeds `SessionActivity.of` as the `background` rung.
    /// Mutually exclusive with `isThinking` — only true between turns.
    var isWaiting: Bool = false
    /// The shim subprocess. Strong reference; nil between init and start, and
    /// for the whole of `.dormant` — a launch-restored session with no pane
    /// has no shim until a pane takes it.
    var shim: ShimProcess?
    /// The WKWebView mounted into the detail pane's ZStack. Strong reference;
    /// nil between init and the first SessionContainer render, and for the
    /// whole of `.dormant` — which never reaches a SessionContainer.
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
