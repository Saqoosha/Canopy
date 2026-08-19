import Foundation

/// Persists per-session titles so the launcher history, sidebar rows, and
/// window title can show something descriptive instead of a raw first prompt.
///
/// A title also records whether the human typed it (`userOwned`). That flag is
/// not decoration — `ShimProcess` regenerates a title several times as a
/// session accumulates prompts, so without a persisted "a human named this"
/// bit every manual rename would be overwritten a few turns later, and again
/// on the next launch.
///
/// **Title and flag live in ONE record, deliberately.** The first version kept
/// them in two UserDefaults keys, and the two had irreconcilable premises about
/// the same state: `migrate` has to move a mark for a session that has no title
/// yet (a rename can land before the CLI reports its real session id), while
/// the housekeeping that kept the keys from drifting deleted exactly those
/// markless entries — so an unrelated automatic save for any other session
/// silently un-owned a title the user had just typed. One record cannot drift
/// from itself, needs no housekeeping, and cannot be half-written by a crash.
enum SessionTitleStore {
    /// One stored title. `userOwned` is part of the value, not a parallel set.
    private struct Record: Codable {
        var text: String
        var userOwned: Bool
    }

    private static let key = "sessionTitles.v2"
    /// Pre-record keys, read once to carry existing titles forward. Writes
    /// never reach them again, so an older Canopy build downgraded onto this
    /// profile keeps whatever it last saw rather than seeing nothing.
    private static let legacyTitlesKey = "sessionTitles"
    private static let legacyUserOwnedKey = "sessionTitlesUserOwned"
    private static let maxEntries = 200

    /// Save a title for a session ID.
    ///
    /// `userOwned: true` marks the title as human-authored, which stops
    /// automatic regeneration. Passing `false` (the default) does NOT clear an
    /// existing mark — automatic generation must never be able to demote a
    /// title the user named. `clearUserOwned` is the only way back.
    /// Returns false when nothing was written. The result is not decoration:
    /// the id must be a CLI session UUID, and a caller that ignores a rejected
    /// write shows the rename as applied while nothing was persisted — the name
    /// then evaporates at the next launch with no log anywhere on the path.
    @discardableResult
    static func save(title: String, forSessionId sessionId: String, userOwned: Bool = false) -> Bool {
        guard !title.isEmpty, UUID(uuidString: sessionId) != nil else { return false }
        var records = all()
        let wasUserOwned = records[sessionId]?.userOwned ?? false
        records[sessionId] = Record(text: title, userOwned: userOwned || wasUserOwned)
        write(evicting: records, protecting: sessionId)
        return true
    }

    /// Look up a saved title for a session ID.
    static func title(forSessionId sessionId: String) -> String? {
        all()[sessionId]?.text
    }

    /// Whether the stored title for this session was typed by a human.
    /// Callers use this to suppress automatic title generation.
    static func isUserOwned(_ sessionId: String) -> Bool {
        all()[sessionId]?.userOwned ?? false
    }

    /// Drop the human-authored mark, letting automatic generation resume.
    ///
    /// Nothing in the shipping UI calls this — `commitRename` treats empty
    /// input as "dismiss" rather than as "revert to automatic". It exists so
    /// the mark is reversible in one place if that affordance is ever added,
    /// and so the probe can exercise the flag in both directions.
    static func clearUserOwned(_ sessionId: String) {
        var records = all()
        guard var record = records[sessionId], record.userOwned else { return }
        record.userOwned = false
        records[sessionId] = record
        write(evicting: records, protecting: sessionId)
    }

    /// Re-key a stored title when a session's id changes (placeholder
    /// `--resume` id → the CLI's real session id). A title generated before
    /// the first `update_session_state` is saved under the placeholder;
    /// without this the reopened session would lose its title. No-op when
    /// nothing is stored under the old id.
    ///
    /// Because the mark travels inside the record, this needs no special case
    /// for "marked but not yet titled" — that state simply cannot exist.
    static func migrate(fromSessionId stale: String, toSessionId sessionId: String) {
        guard stale != sessionId, UUID(uuidString: sessionId) != nil else { return }
        var records = all()
        guard let record = records.removeValue(forKey: stale) else { return }
        records[sessionId] = record
        write(evicting: records, protecting: sessionId)
    }

    // MARK: - Storage

    private static func all() -> [String: Record] {
        if let data = UserDefaults.standard.data(forKey: key),
           let records = try? JSONDecoder().decode([String: Record].self, from: data)
        {
            return records
        }
        return migratedFromLegacyKeys()
    }

    /// Build the record map from the pre-record key pair. Read-only: the legacy
    /// keys are left exactly as they are, so this is idempotent and safe to run
    /// on every read until the first write lands.
    private static func migratedFromLegacyKeys() -> [String: Record] {
        let titles = UserDefaults.standard.dictionary(forKey: legacyTitlesKey) as? [String: String] ?? [:]
        guard !titles.isEmpty else { return [:] }
        let owned = Set(UserDefaults.standard.stringArray(forKey: legacyUserOwnedKey) ?? [])
        return titles.mapValues { Record(text: $0, userOwned: false) }
            .merging(
                owned.compactMap { id in titles[id].map { (id, Record(text: $0, userOwned: true)) } }
                    .reduce(into: [:]) { $0[$1.0] = $1.1 },
                uniquingKeysWith: { _, ownedRecord in ownedRecord }
            )
    }

    /// Persist, trimming to `maxEntries`.
    ///
    /// `protecting` is the key this write exists to store. Swift's dictionary
    /// order is unspecified and hash-seeded, so a plain `keys.prefix(excess)`
    /// can evict the entry inserted one line earlier — a manual rename
    /// discarded by the very call performing it. A user-owned record is also
    /// never evicted while an automatic one remains: a name a human typed is
    /// the most valuable entry in the map, and the old eviction treated it as
    /// the cheapest.
    private static func write(evicting records: [String: Record], protecting protectedId: String?) {
        var records = records
        if records.count > maxEntries {
            let candidates = records.keys
                .filter { $0 != protectedId }
                .sorted { lhs, rhs in
                    let l = records[lhs]?.userOwned ?? false
                    let r = records[rhs]?.userOwned ?? false
                    if l != r { return !l }
                    return lhs < rhs
                }
            for id in candidates.prefix(records.count - maxEntries) {
                records.removeValue(forKey: id)
            }
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    #if DEBUG
    /// Probe support: the raw persisted blob, so a fixture can put the
    /// developer's real store back exactly as it found it. The fixtures write
    /// the live UserDefaults domain (there is no separate test domain), and an
    /// earlier version left two junk titles behind on every local run — which
    /// also pushed the 200-entry cap and could evict a real title.
    static func _probeSnapshot() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    static func _probeRestore(_ snapshot: Data?) {
        if let snapshot {
            UserDefaults.standard.set(snapshot, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    #endif
}
