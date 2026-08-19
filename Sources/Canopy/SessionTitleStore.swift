import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "TitleStore")

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
/// them in two UserDefaults keys, whose housekeeping deleted any mark whose
/// session had no title — while the eviction path could produce exactly that
/// state, by dropping a just-written title (the order was a hash-seeded
/// `keys.prefix`) and leaving its mark behind for the next unrelated automatic
/// save to sweep. So a title the user had just typed could come back un-owned.
/// One record cannot drift from itself, needs no cross-key reconciliation, and
/// cannot be half-written by a crash.
///
/// It still needs housekeeping of the other kind — the entry cap is enforced on
/// every write, and the legacy read runs until the first write lands.
enum SessionTitleStore {
    /// One stored title. `userOwned` is part of the value, not a parallel set.
    private struct Record: Codable {
        var text: String
        var userOwned: Bool
    }

    private static let key = "sessionTitles.v2"
    /// Pre-record keys, read once to carry existing titles forward.
    ///
    /// They are left in place because deleting them buys nothing, NOT because
    /// they give a working downgrade story: they freeze at the first v2 write,
    /// so an older build sees a snapshot missing everything since, and anything
    /// it writes there is invisible on re-upgrade because `load()` finds the v2
    /// blob and never consults them again.
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
        guard case .ok(var records) = load() else { return false }
        let wasUserOwned = records[sessionId]?.userOwned ?? false
        records[sessionId] = Record(text: title, userOwned: userOwned || wasUserOwned)
        return write(evicting: records, protecting: sessionId)
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
        guard case .ok(var records) = load() else { return }
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
        guard case .ok(var records) = load() else { return }
        guard let record = records.removeValue(forKey: stale) else { return }
        records[sessionId] = record
        write(evicting: records, protecting: sessionId)
    }

    // MARK: - Storage

    /// Why `all()` cannot simply return a dictionary.
    ///
    /// `try?` conflates "no blob yet" with "the blob is there and did not
    /// decode", and a write built on that mistake is unrecoverable: one
    /// malformed value fails the whole `[String: Record]` decode, the caller
    /// gets an empty map, inserts one record, and overwrites the key — two
    /// hundred titles gone, every user-owned one among them, with no log. So a
    /// failed decode is a distinct state, and writes refuse to proceed in it.
    private enum Load {
        case ok([String: Record])
        /// A blob exists and could not be decoded. Reads degrade to empty;
        /// writes are refused rather than allowed to overwrite it.
        case unreadable
    }

    private static let brokenKey = "sessionTitles.v2.broken"

    private static func load() -> Load {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .ok(migratedFromLegacyKeys())
        }
        do {
            return .ok(try JSONDecoder().decode([String: Record].self, from: data))
        } catch {
            // Parked, not discarded — the same bargain `SessionStorePersistence`
            // makes for a corrupt filter. A layout is worth one launch; two
            // hundred titles are worth keeping the bytes around for.
            if UserDefaults.standard.data(forKey: brokenKey) == nil {
                UserDefaults.standard.set(data, forKey: brokenKey)
            }
            logger.error("Stored titles did not decode; writes suspended: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
    }

    /// Reads degrade to empty on a corrupt blob. Nothing is destroyed by this —
    /// the rows fall back to their prompt-derived labels for the launch.
    private static func all() -> [String: Record] {
        if case .ok(let records) = load() { return records }
        return [:]
    }

    /// Build the record map from the pre-record key pair. Read-only: the legacy
    /// keys are left exactly as they are, so this is idempotent and safe to run
    /// on every read until the first write lands.
    private static func migratedFromLegacyKeys() -> [String: Record] {
        let titles = UserDefaults.standard.dictionary(forKey: legacyTitlesKey) as? [String: String] ?? [:]
        guard !titles.isEmpty else { return [:] }
        let owned = Set(UserDefaults.standard.stringArray(forKey: legacyUserOwnedKey) ?? [])
        return titles.reduce(into: [String: Record]()) { out, pair in
            out[pair.key] = Record(text: pair.value, userOwned: owned.contains(pair.key))
        }
    }

    /// Persist, trimming to `maxEntries`. Returns false when nothing reached disk.
    ///
    /// `protecting` is the key this write exists to store. Swift's dictionary
    /// order is unspecified and hash-seeded, so a plain `keys.prefix(excess)`
    /// can evict the entry inserted one line earlier — a manual rename
    /// discarded by the very call performing it. A user-owned record is also
    /// never evicted while an automatic one remains, with one literal
    /// exception: the protected key is excluded from the candidates entirely,
    /// so an automatic write can outlive a user-owned record when every other
    /// candidate is user-owned.
    ///
    /// The tiebreak is lexical on the id, not chronological — the record
    /// carries no timestamp, so which of two equally-owned entries goes is
    /// arbitrary rather than oldest-first. Nothing here claims otherwise, and
    /// fixing it needs a new field.
    @discardableResult
    private static func write(evicting records: [String: Record], protecting protectedId: String?) -> Bool {
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
            let doomed = candidates.prefix(records.count - maxEntries)
            let ownedLost = doomed.filter { records[$0]?.userOwned == true }.count
            for id in doomed { records.removeValue(forKey: id) }
            // Silent eviction of a name a human chose is the one loss here that
            // cannot be regenerated, so it is reported even though it is rare.
            logger.notice("Evicted \(doomed.count, privacy: .public) stored titles (\(ownedLost, privacy: .public) user-named)")
        }
        guard let data = try? JSONEncoder().encode(records) else {
            logger.error("Stored titles failed to encode; nothing written")
            return false
        }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    #if DEBUG
    /// Probe support: every key this type touches, so a fixture can put the
    /// developer's real store back exactly as it found it. The fixtures write
    /// the live UserDefaults domain (there is no separate test domain), and an
    /// earlier version left two junk titles behind on every local run — which
    /// also pushed the entry cap and could evict a real title.
    ///
    /// All THREE keys, not just the v2 blob: a fixture covering the legacy
    /// migration has to write the old pair, and with no restore hook for them
    /// the only way to write that fixture would clobber real state.
    static func _probeSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for k in [key, legacyTitlesKey, legacyUserOwnedKey, brokenKey] {
            if let value = UserDefaults.standard.object(forKey: k) { snapshot[k] = value }
        }
        return snapshot
    }

    static func _probeRestore(_ snapshot: [String: Any]) {
        for k in [key, legacyTitlesKey, legacyUserOwnedKey, brokenKey] {
            if let value = snapshot[k] {
                UserDefaults.standard.set(value, forKey: k)
            } else {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    /// Probe support: start from a known-empty store.
    static func _probeReset() {
        for k in [key, legacyTitlesKey, legacyUserOwnedKey, brokenKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    /// Probe support: how many records are stored, without exposing the map.
    static func _probeCount() -> Int { all().count }

    /// Probe support: the entry cap, so fixtures derive it instead of re-typing.
    static var _probeMaxEntries: Int { maxEntries }

    /// Probe support: make the stored blob undecodable, to exercise the
    /// fail-closed path. Goes through the constant so no fixture re-types the
    /// key name.
    static func _probeCorrupt() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
    }

    /// Probe support: whether an unreadable blob was parked rather than lost.
    static func _probeHasParkedBlob() -> Bool {
        UserDefaults.standard.data(forKey: brokenKey) != nil
    }

    /// Probe support: plant the pre-record key pair, to exercise the migration.
    static func _probeSeedLegacy(titles: [String: String], owned: [String]) {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(titles, forKey: legacyTitlesKey)
        UserDefaults.standard.set(owned, forKey: legacyUserOwnedKey)
    }
    #endif
}
