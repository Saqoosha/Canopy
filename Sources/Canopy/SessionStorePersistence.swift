import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Persistence")

/// UserDefaults-backed persistence for `SessionStore`.
///
/// Always-on state: filter facets, grouping mode, hidden ids, and the
/// resumeId of the last-active session (so the sidebar can highlight that
/// row on cold launch).
///
/// Opt-in state: the pane/session restore snapshot. It is written only when
/// the user picks "Save and Quit" at the quit prompt, and it is deleted the
/// moment the next launch reads it — see `SessionRestoreSnapshot` and
/// `SessionStore.makeRestored()`.
enum SessionStorePersistence {
    private static let filterKey = "canopy.sidebarFilter.v1"
    private static let lastActiveResumeKey = "canopy.lastActiveResumeId.v1"
    private static let hiddenIdsKey = "canopy.hiddenSessionIds.v1"
    private static let groupingModeKey = "canopy.groupingMode.v1"
    private static let restoreSnapshotKey = "canopy.sessionRestore.v1"

    // MARK: - Hidden sessions

    static func loadHiddenIds() -> Set<String> {
        guard let arr = UserDefaults.standard.stringArray(forKey: hiddenIdsKey) else {
            return []
        }
        return Set(arr)
    }

    static func saveHiddenIds(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: hiddenIdsKey)
    }

    // MARK: - Filter

    static func loadFilter() -> SidebarFilter {
        guard let data = UserDefaults.standard.data(forKey: filterKey) else {
            return SidebarFilter()
        }
        do {
            return try JSONDecoder().decode(SidebarFilter.self, from: data)
        } catch {
            logger.warning("loadFilter decode failed: \(error.localizedDescription, privacy: .public) — falling back to default")
            // Move the bad blob aside so the next launch isn't blocked on it.
            UserDefaults.standard.set(data, forKey: filterKey + ".broken")
            UserDefaults.standard.removeObject(forKey: filterKey)
            return SidebarFilter()
        }
    }

    static func saveFilter(_ filter: SidebarFilter) {
        do {
            let data = try JSONEncoder().encode(filter)
            UserDefaults.standard.set(data, forKey: filterKey)
        } catch {
            logger.warning("saveFilter encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Last active session

    static func loadLastActiveResumeId() -> String? {
        UserDefaults.standard.string(forKey: lastActiveResumeKey)
    }

    static func saveLastActiveResumeId(_ resumeId: String?) {
        if let resumeId {
            UserDefaults.standard.set(resumeId, forKey: lastActiveResumeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastActiveResumeKey)
        }
    }

    // MARK: - Grouping mode

    static func loadGroupingMode() -> GroupingMode {
        guard let raw = UserDefaults.standard.string(forKey: groupingModeKey),
              let mode = GroupingMode(rawValue: raw) else {
            return .date
        }
        return mode
    }

    static func saveGroupingMode(_ mode: GroupingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: groupingModeKey)
    }

    // MARK: - Launch restore snapshot

    static func loadRestoreSnapshot() -> SessionRestoreSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: restoreSnapshotKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(SessionRestoreSnapshot.self, from: data)
        } catch {
            logger.warning("loadRestoreSnapshot decode failed: \(error.localizedDescription, privacy: .public) — discarding")
            // A stale layout is not worth keeping (unlike the filter); the next
            // quit rewrites the key, so discard instead of stashing a .broken copy.
            UserDefaults.standard.removeObject(forKey: restoreSnapshotKey)
            return nil
        }
    }

    static func saveRestoreSnapshot(_ snapshot: SessionRestoreSnapshot) {
        if snapshot.isEmpty {
            clearRestoreSnapshot()
            return
        }
        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: restoreSnapshotKey)
        } catch {
            logger.warning("saveRestoreSnapshot encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clearRestoreSnapshot() {
        UserDefaults.standard.removeObject(forKey: restoreSnapshotKey)
    }
}
