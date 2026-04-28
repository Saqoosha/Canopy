import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Persistence")

/// UserDefaults-backed persistence for `SessionStore`.
///
/// Phase A scope (intentionally narrow):
///   - Filter facets persist across launches.
///   - The resumeId of the last-active session persists so the sidebar can
///     highlight that row on cold launch.
///
/// We do NOT persist the open-sessions list yet. On launch, the sidebar
/// shows whatever closed local/cloud rows exist; the user clicks to reopen.
/// PR D may add full open-list restoration if real users miss it.
enum SessionStorePersistence {
    private static let filterKey = "canopy.sidebarFilter.v1"
    private static let lastActiveResumeKey = "canopy.lastActiveResumeId.v1"
    private static let hiddenIdsKey = "canopy.hiddenSessionIds.v1"

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
}
