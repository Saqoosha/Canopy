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
    case bypassPermissions = "bypassPermissions"

    var displayName: String {
        switch self {
        case .default: "Default (ask each time)"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        case .plan: "Plan Mode"
        case .bypassPermissions: "Bypass All"
        }
    }
}

@Observable
final class AppState {
    private(set) var screen: AppScreen = .launcher
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode {
        get { CanopySettings.shared.initialPermissionMode }
        set { CanopySettings.shared.initialPermissionMode = newValue }
    }
    var resumeSessionId: String?
    var resumeSessionTitle: String?
    var debugAutoLaunchDir: String?
    /// Incremented to force SwiftUI to recreate the WebViewContainer (via .id() modifier),
    /// ensuring a fresh WKWebView for each session.
    private(set) var webviewReloadToken = 0

    init() {
        debugAutoLaunchDir = UserDefaults.standard.string(forKey: "debugAutoLaunchDir")
    }

    /// Optional reference to the status bar data, set by TabContentView.
    weak var statusBarData: StatusBarData?

    func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil) {
        RecentDirectories.add(directory)
        workingDirectory = directory
        self.resumeSessionId = resumeSessionId
        self.resumeSessionTitle = sessionTitle
        statusBarData?.resetAll()
        webviewReloadToken += 1
        screen = .session
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) mode=\(self.permissionMode.rawValue, privacy: .public)")
    }

    func backToLauncher() {
        resumeSessionId = nil
        screen = .launcher
    }
}
