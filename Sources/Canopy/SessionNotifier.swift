import UserNotifications
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionNotifier")

/// The local banner for a session event. One place for the in-process shim and
/// for a daemon session's Mac client, which decide separately whether to show it.
enum SessionNotifier {
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("Notification error: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
