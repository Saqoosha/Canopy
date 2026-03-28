import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "AppState")

enum AppScreen {
    case launcher
    case session
}

enum PermissionMode: String, CaseIterable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case bypassPermissions = "bypassPermissions"

    var displayName: String {
        switch self {
        case .default: "Default (ask each time)"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan Mode"
        case .bypassPermissions: "Bypass All"
        }
    }
}

@Observable
final class AppState {
    private(set) var screen: AppScreen = .launcher
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode = .acceptEdits
    var resumeSessionId: String?
    /// Incremented to force SwiftUI to recreate the WebViewContainer (via .id() modifier),
    /// ensuring a fresh WKWebView for each session.
    private(set) var webviewReloadToken = 0

    func launchSession(directory: URL, resumeSessionId: String? = nil) {
        RecentDirectories.add(directory)
        workingDirectory = directory
        self.resumeSessionId = resumeSessionId
        webviewReloadToken += 1
        screen = .session
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public)")
    }

    func backToLauncher() {
        resumeSessionId = nil
        screen = .launcher
    }
}
