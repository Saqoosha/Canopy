import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "AppState")

enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case auto = "auto"
    case plan = "plan"
    case dontAsk = "dontAsk"
    case bypassPermissions = "bypassPermissions"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: "Default"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        case .plan: "Plan"
        case .dontAsk: "Don't Ask"
        case .bypassPermissions: "Bypass All"
        }
    }
}

@Observable
final class AppState {
    /// Receives every launch. Set by the launcher's owner, and called by this
    /// object rather than observed by a view: a Start can await seconds of
    /// naming and worktree checkout first, and the view that started it may be
    /// gone by then — the pane given other content meanwhile. A view-side
    /// `onChange` died with it and the session never opened; the task awaiting
    /// the launch holds this object, so this closure still runs.
    @ObservationIgnored var onLaunch: ((AppState) -> Void)?
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode = .acceptEdits
    var model: String?
    var effortLevel: String?
    /// Whether Cmd was held when the launch was asked for.
    ///
    /// Stamped rather than read at hand-off: a launch can land after an SSH
    /// round trip or a worktree checkout, long after Cmd was released.
    ///
    /// Written only by `launchSession`, from its `openInNewPane` parameter, so
    /// no route can be added that forgets to stamp it. Stamping at each call
    /// site was the first revision and a reviewer measured what it missed: two
    /// of the four routes never stamped, so the session-history row lost its
    /// Cmd gesture and a stale `true` from an earlier press opened a pane
    /// nobody asked for.
    private(set) var openInNewPane = false
    var resumeSessionId: String?
    var resumeSessionTitle: String?

    /// The first turn composed on the launch screen (text and/or images), to be submitted as the session's
    /// first turn once its CLI is up. Nil for every route that has no launch
    /// screen behind it (a sidebar click, a restore, Cmd+O).
    var initialPrompt: LaunchPrompt?
    /// A title generated together with the session's worktree branch, to be
    /// kept rather than regenerated. Nil for every other launch — see
    /// `OpenSession.pendingSettledTitle`.
    var settledTitle: String?
    var remoteHost: String?
    var customApi: ModelProvider?
    var debugAutoLaunchDir: String?
    /// Incremented to force SwiftUI to recreate the WebViewContainer (via .id() modifier),
    /// ensuring a fresh WKWebView for each session.
    private(set) var webviewReloadToken = 0

    init() {
        debugAutoLaunchDir = UserDefaults.standard.string(forKey: "debugAutoLaunchDir")
    }

    /// `openInNewPane`: nil means "sample the modifier now", which is right for
    /// every caller that runs in the same turn as the click. A caller that
    /// awaits first must capture the value BEFORE awaiting and pass it.
    func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, remoteHost: String? = nil, customApi: ModelProvider? = nil, openInNewPane: Bool? = nil, initialPrompt: LaunchPrompt? = nil, settledTitle: String? = nil) {
        self.openInNewPane = openInNewPane ?? NSEvent.modifierFlags.contains(.command)
        // Don't add remote paths to local recent directories
        if remoteHost == nil {
            RecentDirectories.add(directory)
        }
        workingDirectory = directory
        self.resumeSessionId = resumeSessionId
        self.resumeSessionTitle = sessionTitle
        self.initialPrompt = initialPrompt
        self.settledTitle = settledTitle
        self.model = model
        self.effortLevel = effortLevel
        self.permissionMode = permissionMode
        self.remoteHost = remoteHost
        self.customApi = customApi
        webviewReloadToken += 1
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) model=\(model ?? "auto", privacy: .public) effort=\(effortLevel ?? "auto", privacy: .public) mode=\(permissionMode.rawValue, privacy: .public) remote=\(remoteHost ?? "local", privacy: .public) customApi=\(customApi?.isEnabled == true ? "yes" : "no", privacy: .public)")
        onLaunch?(self)
    }

    func backToLauncher() {
        resumeSessionId = nil
        // Cleared with the rest of the hand-off state, or the NEXT session
        // started from this launcher would submit the previous one's prompt.
        initialPrompt = nil
        settledTitle = nil
        remoteHost = nil
    }
}
