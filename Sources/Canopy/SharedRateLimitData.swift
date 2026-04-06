import Foundation
import Observation

/// Account-level rate limit data shared across all tabs.
/// Rate limits (5hr session, weekly) are per-account, not per-session,
/// so a single shared instance avoids redundant updates from each tab.
@MainActor
@Observable
final class SharedRateLimitData {
    static let shared = SharedRateLimitData()

    // 5hr session rate limit
    var sessionPct: Int = 0
    var sessionResetDate: Date?

    // 7-day all-models rate limit
    var weeklyPct: Int = 0
    var weeklyResetDate: Date?

    // 7-day Sonnet-only rate limit
    var weeklyPctSonnet: Int = 0
    var weeklyResetDateSonnet: Date?

    // Throttle: only one tab needs to request usage updates
    private var lastUsageUpdateTime: Date = .distantPast
    private static let updateInterval: TimeInterval = 60

    private init() {}

    /// Returns true if enough time has passed since the last update request.
    /// Call this before sending request_usage_update — only the first tab to call wins.
    func shouldRequestUpdate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastUsageUpdateTime) >= Self.updateInterval else { return false }
        lastUsageUpdateTime = now
        return true
    }

    func update(from utilization: [String: Any]) {
        if let entry = utilization["fiveHour"] as? [String: Any] {
            sessionPct = entry["utilization"].map { Self.parseUtilization($0) } ?? 0
            sessionResetDate = (entry["resetsAt"] as? String).flatMap { Self.parseISO8601($0) }
        }
        if let entry = utilization["sevenDay"] as? [String: Any] {
            weeklyPct = entry["utilization"].map { Self.parseUtilization($0) } ?? 0
            weeklyResetDate = (entry["resetsAt"] as? String).flatMap { Self.parseISO8601($0) }
        }
        if let sevenDaySonnet = utilization["sevenDaySonnet"] as? [String: Any] {
            weeklyPctSonnet = sevenDaySonnet["utilization"].map { Self.parseUtilization($0) } ?? 0
            weeklyResetDateSonnet = (sevenDaySonnet["resetsAt"] as? String).flatMap { Self.parseISO8601($0) }
        } else {
            weeklyPctSonnet = 0
            weeklyResetDateSonnet = nil
        }
    }

    /// Effective weekly limit: Sonnet-specific when using Sonnet, otherwise all-models.
    func effectiveWeeklyPct(for model: String) -> Int {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyPctSonnet : weeklyPct
    }

    func effectiveWeeklyResetDate(for model: String) -> Date? {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyResetDateSonnet : weeklyResetDate
    }

    // MARK: - Parsing helpers

    private static func parseUtilization(_ value: Any) -> Int {
        if let intVal = value as? Int {
            return min(100, max(0, intVal))
        } else if let doubleVal = value as? Double {
            let pct = doubleVal <= 1.0 ? doubleVal * 100 : doubleVal
            return Int(min(100, max(0, pct)))
        }
        return 0
    }

    private static func parseISO8601(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        return ISO8601DateFormatter().date(from: isoString)
    }
}
