import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "AppState")

enum AppScreen {
    case launcher
    case session
}

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
    private(set) var screen: AppScreen = .launcher
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode = .acceptEdits
    var model: String?
    var effortLevel: String?
    /// Whether Cmd was held when the launch was asked for.
    ///
    /// `Detail` used to read `NSEvent.modifierFlags` in its `screen` observer,
    /// which for a synchronous launch was the click instant. The remote branch
    /// of `LauncherView.launchLocal` awaits an SSH round trip first, so that
    /// observer can now fire a minute later and would sample whatever is held
    /// then — a Cmd+click that opens no new pane, or a plain click that opens
    /// one.
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
    func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, remoteHost: String? = nil, customApi: ModelProvider? = nil, openInNewPane: Bool? = nil) {
        self.openInNewPane = openInNewPane ?? NSEvent.modifierFlags.contains(.command)
        // Don't add remote paths to local recent directories
        if remoteHost == nil {
            RecentDirectories.add(directory)
        }
        workingDirectory = directory
        self.resumeSessionId = resumeSessionId
        self.resumeSessionTitle = sessionTitle
        self.model = model
        self.effortLevel = effortLevel
        self.permissionMode = permissionMode
        self.remoteHost = remoteHost
        self.customApi = customApi
        webviewReloadToken += 1
        screen = .session
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) model=\(model ?? "auto", privacy: .public) effort=\(effortLevel ?? "auto", privacy: .public) mode=\(permissionMode.rawValue, privacy: .public) remote=\(remoteHost ?? "local", privacy: .public) customApi=\(customApi?.isEnabled == true ? "yes" : "no", privacy: .public)")
    }

    func backToLauncher() {
        resumeSessionId = nil
        remoteHost = nil
        screen = .launcher
    }
}
