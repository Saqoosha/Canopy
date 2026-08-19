import Foundation

/// Persists AI-generated session titles so the launcher history and window title
/// can show descriptive titles instead of raw first prompts.
/// Same approach as Sessylph — titles are saved when `generate_session_title_response` arrives.
///
/// A title can additionally be marked **user-owned**: the human typed it via
/// Rename. That flag is not decoration — `ShimProcess` regenerates a title
/// several times as a session accumulates prompts (a title generated from a
/// one-word opening is worthless, so the first one is deliberately not final),
/// and without a persisted "a human named this" bit every manual rename would
/// be overwritten a few turns later, and again on the next launch.
enum SessionTitleStore {
    private static let key = "sessionTitles"
    /// Session ids whose title was typed by the user. Stored as a separate
    /// array rather than folded into `sessionTitles` so the existing
    /// `[String: String]` shape — and every build that reads it — stays valid.
    private static let userOwnedKey = "sessionTitlesUserOwned"
    private static let maxEntries = 200

    /// Save a title for a session ID.
    ///
    /// `userOwned: true` marks the title as human-authored, which makes
    /// `isUserOwned` report true and stops automatic regeneration. Passing
    /// `false` (the default) does NOT clear an existing mark — automatic
    /// generation must never be able to demote a title the user named. Use
    /// `clearUserOwned` for that, which only the rename UI has cause to call.
    static func save(title: String, forSessionId sessionId: String, userOwned: Bool = false) {
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
        if userOwned {
            var owned = userOwnedIds()
            owned.insert(sessionId)
            writeUserOwned(owned, keepingOnly: titles)
        } else {
            // An eviction above can drop a session that was user-owned; keep
            // the two keys from drifting apart forever.
            pruneUserOwned(against: titles)
        }
    }

    /// Look up a saved title for a session ID.
    static func title(forSessionId sessionId: String) -> String? {
        all()[sessionId]
    }

    /// Whether the stored title for this session was typed by a human.
    /// Callers use this to suppress automatic title generation.
    static func isUserOwned(_ sessionId: String) -> Bool {
        userOwnedIds().contains(sessionId)
    }

    /// Drop the human-authored mark, letting automatic generation resume.
    static func clearUserOwned(_ sessionId: String) {
        var owned = userOwnedIds()
        guard owned.remove(sessionId) != nil else { return }
        writeUserOwned(owned, keepingOnly: all())
    }

    /// Re-key a stored title when a session's id changes (placeholder
    /// `--resume` id → the CLI's real session id). A title generated before
    /// the first `update_session_state` is saved under the placeholder;
    /// without this the reopened session would lose its AI title. No-op
    /// when nothing is stored under the old id.
    ///
    /// The user-owned mark is re-keyed alongside. It has to move even when no
    /// title does: the rename sheet can name a session before its real id
    /// arrives, and a mark left on the placeholder would let generation
    /// overwrite the name one turn later.
    static func migrate(fromSessionId stale: String, toSessionId sessionId: String) {
        guard stale != sessionId, UUID(uuidString: sessionId) != nil else { return }
        var owned = userOwnedIds()
        if owned.remove(stale) != nil {
            owned.insert(sessionId)
            UserDefaults.standard.set(Array(owned), forKey: userOwnedKey)
        }
        var titles = all()
        guard let title = titles.removeValue(forKey: stale) else { return }
        titles[sessionId] = title
        UserDefaults.standard.set(titles, forKey: key)
    }

    /// All stored titles.
    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func userOwnedIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userOwnedKey) ?? [])
    }

    private static func writeUserOwned(_ owned: Set<String>, keepingOnly titles: [String: String]) {
        UserDefaults.standard.set(Array(owned.intersection(titles.keys)), forKey: userOwnedKey)
    }

    private static func pruneUserOwned(against titles: [String: String]) {
        let owned = userOwnedIds()
        let kept = owned.intersection(titles.keys)
        guard kept.count != owned.count else { return }
        UserDefaults.standard.set(Array(kept), forKey: userOwnedKey)
    }
}
