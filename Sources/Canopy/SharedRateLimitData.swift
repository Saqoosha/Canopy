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

    /// Per-model weekly buckets from the raw usage payload's `model_scoped`
    /// array (e.g. "Weekly Fable"). Only the raw CLI `get_usage` path fills
    /// this — the extension's usage_update transform drops the field.
    struct ModelScopedLimit: Equatable {
        let displayName: String
        let pct: Int
        let resetDate: Date?
    }

    var modelScoped: [ModelScopedLimit] = []

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

    /// Update from the RAW `/api/oauth/usage` shape (snake_case), delivered
    /// via the CLI's `get_usage` response. Unlike `update(from:)` (the
    /// extension's camelCase usage_update) this includes `model_scoped`.
    /// Shape: { five_hour: {utilization, resets_at}, seven_day: {...},
    ///          seven_day_sonnet: {...}, model_scoped: [{display_name,
    ///          utilization, resets_at}, ...] }
    func updateFromRawUsage(_ rateLimits: [String: Any]) {
        if let entry = rateLimits["five_hour"] as? [String: Any] {
            sessionPct = entry["utilization"].map { Self.parseUtilization($0) } ?? 0
            sessionResetDate = (entry["resets_at"] as? String).flatMap { Self.parseISO8601($0) }
        }
        if let entry = rateLimits["seven_day"] as? [String: Any] {
            weeklyPct = entry["utilization"].map { Self.parseUtilization($0) } ?? 0
            weeklyResetDate = (entry["resets_at"] as? String).flatMap { Self.parseISO8601($0) }
        }
        if let entry = rateLimits["seven_day_sonnet"] as? [String: Any] {
            weeklyPctSonnet = entry["utilization"].map { Self.parseUtilization($0) } ?? 0
            weeklyResetDateSonnet = (entry["resets_at"] as? String).flatMap { Self.parseISO8601($0) }
        }
        if let scoped = rateLimits["model_scoped"] as? [[String: Any]] {
            modelScoped = scoped.compactMap { entry in
                guard let name = entry["display_name"] as? String, !name.isEmpty else { return nil }
                return ModelScopedLimit(
                    displayName: name,
                    pct: entry["utilization"].map { Self.parseUtilization($0) } ?? 0,
                    resetDate: (entry["resets_at"] as? String).flatMap { Self.parseISO8601($0) }
                )
            }
        } else {
            modelScoped = []
        }
    }

    /// Effective weekly limit: Sonnet-specific when using Sonnet, otherwise all-models.
    func effectiveWeeklyPct(for model: String) -> Int {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyPctSonnet : weeklyPct
    }

    func effectiveWeeklyResetDate(for model: String) -> Date? {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyResetDateSonnet : weeklyResetDate
    }

    // MARK: - Formatting

    /// Format reset Date as relative string: "18m", "2h05m", "4d", "soon"
    static nonisolated func formatResetTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "soon" }

        let minutes = seconds / 60
        if minutes == 0 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainMinutes = minutes % 60
        if hours < 24 {
            return remainMinutes > 0 ? "\(hours)h\(String(format: "%02d", remainMinutes))m" : "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    /// Format reset Date as absolute date+time, e.g. "Today at 6:09 PM" or "May 20 at 12:00 AM".
    /// MainActor-isolated (inherits from class) — DateFormatter is reused per call by SwiftUI body redraws.
    static func formatAbsoluteResetTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterStandard = ISO8601DateFormatter()

    private static func parseISO8601(_ isoString: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: isoString) { return date }
        return isoFormatterStandard.date(from: isoString)
    }
}
