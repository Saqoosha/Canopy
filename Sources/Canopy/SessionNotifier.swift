import UserNotifications
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionNotifier")

/// The local banner for a session event. One place for the in-process shim and
/// for a daemon session's Mac client, which decide separately whether to show it.
enum SessionNotifier {
    static let showWhileFrontmostKey = "canopy.showWhileFrontmost"

    static func post(title: String, body: String, showWhileFrontmost: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if showWhileFrontmost { content.userInfo[showWhileFrontmostKey] = true }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("Notification error: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// Without a delegate macOS drops every banner while the app is frontmost; this shows only the opted-in ones.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ForegroundNotificationPresenter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.userInfo[SessionNotifier.showWhileFrontmostKey] as? Bool == true ? [.banner, .sound] : []
    }
}
