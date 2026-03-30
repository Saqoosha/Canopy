import Foundation

/// Persists AI-generated session titles so the launcher history and window title
/// can show descriptive titles instead of raw first prompts.
/// Same approach as Sessylph — titles are saved when `generate_session_title_response` arrives.
enum SessionTitleStore {
    private static let key = "sessionTitles"
    private static let maxEntries = 200

    /// Save a title for a session ID.
    static func save(title: String, forSessionId sessionId: String) {
        guard !title.isEmpty, UUID(uuidString: sessionId) != nil else { return }
        var titles = all()
        titles[sessionId] = title
        if titles.count > maxEntries {
            let excess = titles.count - maxEntries
            for key in titles.keys.prefix(excess) {
                titles.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(titles, forKey: key)
    }

    /// Look up a saved title for a session ID.
    static func title(forSessionId sessionId: String) -> String? {
        all()[sessionId]
    }

    /// All stored titles.
    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
