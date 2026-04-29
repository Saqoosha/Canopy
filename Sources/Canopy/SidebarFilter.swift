import Foundation

/// Persisted filter state for the sidebar. Saved to UserDefaults under
/// `canopy.sidebarFilter.v1`. Defaults are "All" everywhere.
struct SidebarFilter: Codable, Equatable, Sendable {
    enum StatusFilter: String, CaseIterable, Codable, Sendable {
        case all
        case openOnly = "open"
        case closedOnly = "closed"

        var displayName: String {
            switch self {
            case .all: "All"
            case .openOnly: "Open only"
            case .closedOnly: "Closed only"
            }
        }
    }

    enum OriginFilter: String, CaseIterable, Codable, Sendable {
        case all
        case local
        case cloud

        var displayName: String {
            switch self {
            case .all: "All"
            case .local: "Local"
            case .cloud: "Cloud"
            }
        }
    }

    enum LastActivityFilter: String, CaseIterable, Codable, Sendable {
        case all
        case today
        case week
        case month

        var displayName: String {
            switch self {
            case .all: "All time"
            case .today: "Today"
            case .week: "Past 7 days"
            case .month: "Past 30 days"
            }
        }

        /// The cutoff Date below which rows are excluded. nil = no filtering.
        func cutoff(now: Date = Date()) -> Date? {
            switch self {
            case .all: return nil
            case .today:
                return Calendar.current.startOfDay(for: now)
            case .week:
                return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .month:
                return Calendar.current.date(byAdding: .day, value: -30, to: now)
            }
        }
    }

    var status: StatusFilter = .all
    var origin: OriginFilter = .all
    /// nil means "All projects". Otherwise the project label must match exactly.
    var project: String? = nil
    var lastActivity: LastActivityFilter = .all

    /// True when any facet is non-default — drives the filter-active dot on
    /// the gear icon.
    var isActive: Bool {
        status != .all || origin != .all || project != nil || lastActivity != .all
    }

    /// Apply this filter to a list of rows. Pure function — easy to unit test.
    func apply(to rows: [SidebarRow], now: Date = Date()) -> [SidebarRow] {
        let cutoff = lastActivity.cutoff(now: now)
        return rows.filter { row in
            switch status {
            case .all: break
            case .openOnly where !row.isOpen: return false
            case .closedOnly where row.isOpen: return false
            default: break
            }
            switch origin {
            case .all: break
            case .local where row.origin != .local: return false
            case .cloud where row.origin != .cloud: return false
            default: break
            }
            if let project, row.project != project { return false }
            if let cutoff, row.lastModified < cutoff { return false }
            return true
        }
    }

    /// Distinct project labels in the input — used to populate the Project
    /// picker. Sorted alphabetically; an "All" entry is added by the UI.
    static func projects(in rows: [SidebarRow]) -> [String] {
        let set = Set(rows.map(\.project))
        return set.sorted()
    }
}
