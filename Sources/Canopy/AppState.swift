import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "AppState")

enum AppScreen {
    case launcher
    case session
}

enum PermissionMode: String, CaseIterable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case auto = "auto"
    case plan = "plan"
    case dontAsk = "dontAsk"
    case bypassPermissions = "bypassPermissions"

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
    var resumeSessionId: String?
    var resumeSessionTitle: String?
    var remoteHost: String?
    var debugAutoLaunchDir: String?
    /// Incremented to force SwiftUI to recreate the WebViewContainer (via .id() modifier),
    /// ensuring a fresh WKWebView for each session.
    private(set) var webviewReloadToken = 0

    init() {
        debugAutoLaunchDir = UserDefaults.standard.string(forKey: "debugAutoLaunchDir")
    }

    /// Optional reference to the status bar data, set by TabContentView.
    weak var statusBarData: StatusBarData?

    func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, remoteHost: String? = nil) {
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
        statusBarData?.resetAll()
        webviewReloadToken += 1
        screen = .session
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) model=\(model ?? "auto", privacy: .public) effort=\(effortLevel ?? "auto", privacy: .public) mode=\(permissionMode.rawValue, privacy: .public) remote=\(remoteHost ?? "local", privacy: .public)")
    }

    func backToLauncher() {
        resumeSessionId = nil
        remoteHost = nil
        screen = .launcher
    }
}
