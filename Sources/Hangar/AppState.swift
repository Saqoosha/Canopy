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
    private static let permissionModeKey = "lastPermissionMode"

    private(set) var screen: AppScreen = .launcher
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode = .acceptEdits {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: Self.permissionModeKey) }
    }
    var resumeSessionId: String?
    var resumeSessionTitle: String?
    var debugAutoLaunchDir: String?
    /// Incremented to force SwiftUI to recreate the WebViewContainer (via .id() modifier),
    /// ensuring a fresh WKWebView for each session.
    private(set) var webviewReloadToken = 0

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.permissionModeKey),
           let mode = PermissionMode(rawValue: saved)
        {
            permissionMode = mode
        }
        // Debug: auto-launch session via defaults write sh.saqoo.Hangar debugAutoLaunchDir /tmp
        debugAutoLaunchDir = UserDefaults.standard.string(forKey: "debugAutoLaunchDir")
    }

    func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil) {
        RecentDirectories.add(directory)
        workingDirectory = directory
        self.resumeSessionId = resumeSessionId
        self.resumeSessionTitle = sessionTitle
        webviewReloadToken += 1
        screen = .session
        logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) mode=\(self.permissionMode.rawValue, privacy: .public)")
    }

    func backToLauncher() {
        resumeSessionId = nil
        screen = .launcher
    }
}
