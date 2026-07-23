import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RateLimit")

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
    /// array (e.g. "Weekly Fable").
    ///
    /// Staleness caveat: ONLY the raw CLI `get_usage` path
    /// (`updateFromRawUsage`) writes this — the extension's usage_update
    /// transform drops the field, so `update(from:)` deliberately leaves
    /// it untouched. If the raw path ever stops responding, the 5hr/weekly
    /// bars keep updating while these rows silently freeze at their last
    /// value; `extractRawUsage`'s shape-mismatch warning in ShimProcess is
    /// the discovery signal for that failure.
    struct ModelScopedLimit: Equatable, Identifiable {
        let displayName: String
        let pct: Int
        let resetDate: Date?

        /// SidebarAccountSection's ForEach identity. The server owns the
        /// names, so `updateFromRawUsage` also dedupes on this.
        var id: String { displayName }

        /// Validating construction from one raw `model_scoped` entry —
        /// keeps the parse rules (non-empty name, clamped pct, ISO8601
        /// reset) inside the type instead of at the call site.
        init?(json: [String: Any]) {
            guard let name = json["display_name"] as? String, !name.isEmpty else { return nil }
            displayName = name
            pct = SharedRateLimitData.parseUtilizationStrict(json["utilization"]) ?? 0
            resetDate = (json["resets_at"] as? String).flatMap { SharedRateLimitData.parseISO8601($0) }
        }
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
    ///
    /// Two writers race into the same fields every ~60 s (this raw path +
    /// the extension's transform), so a present-but-unparseable field
    /// keeps the previous value instead of degrading to 0/nil — one
    /// malformed raw payload must not zero a bar or blank the whole
    /// sidebar Usage section (whose visibility keys off the reset dates).
    func updateFromRawUsage(_ rateLimits: [String: Any]) {
        if let entry = rateLimits["five_hour"] as? [String: Any] {
            applyRawWindow(entry, label: "five_hour", pct: &sessionPct, reset: &sessionResetDate)
        }
        if let entry = rateLimits["seven_day"] as? [String: Any] {
            applyRawWindow(entry, label: "seven_day", pct: &weeklyPct, reset: &weeklyResetDate)
        }
        if let entry = rateLimits["seven_day_sonnet"] as? [String: Any] {
            applyRawWindow(entry, label: "seven_day_sonnet", pct: &weeklyPctSonnet, reset: &weeklyResetDateSonnet)
        } else {
            // Mirror update(from:): an absent Sonnet bucket means the
            // account no longer has one — clear it so the two update
            // paths can't disagree based on response ordering.
            weeklyPctSonnet = 0
            weeklyResetDateSonnet = nil
        }
        if let scoped = rateLimits["model_scoped"] as? [[String: Any]] {
            // Dedupe on displayName (the ForEach identity) — server-owned
            // values carry no uniqueness guarantee, and duplicate IDs are
            // undefined behavior for SwiftUI's ForEach.
            var seen = Set<String>()
            modelScoped = scoped.compactMap { ModelScopedLimit(json: $0) }
                .filter { seen.insert($0.displayName).inserted }
        } else {
            modelScoped = []
        }
    }

    /// Apply one raw rate-limit window in place. Present-but-malformed
    /// fields keep the previous value (with a log); a genuinely absent
    /// `resets_at` clears the date (the window really has no reset).
    private func applyRawWindow(_ entry: [String: Any], label: String, pct: inout Int, reset: inout Date?) {
        if let parsed = Self.parseUtilizationStrict(entry["utilization"]) {
            pct = parsed
        } else {
            logger.warning("raw usage \(label, privacy: .public): unparseable utilization (\(String(describing: entry["utilization"]), privacy: .public)); keeping previous")
        }
        if let iso = entry["resets_at"] as? String {
            if let date = Self.parseISO8601(iso) {
                reset = date
            } else {
                logger.warning("raw usage \(label, privacy: .public): unparseable resets_at '\(iso, privacy: .public)'; keeping previous")
            }
        } else if entry["resets_at"] == nil {
            reset = nil
        } else {
            logger.warning("raw usage \(label, privacy: .public): non-string resets_at; keeping previous")
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

    private nonisolated static func parseUtilization(_ value: Any) -> Int {
        parseUtilizationStrict(value) ?? 0
    }

    /// nil when the value is missing or not numeric — lets raw-payload
    /// callers distinguish "malformed" (keep previous value) from a real 0.
    /// nonisolated: also called from ModelScopedLimit.init?(json:), which
    /// does not inherit the class's MainActor isolation.
    private nonisolated static func parseUtilizationStrict(_ value: Any?) -> Int? {
        if let intVal = value as? Int {
            return min(100, max(0, intVal))
        } else if let doubleVal = value as? Double {
            let pct = doubleVal <= 1.0 ? doubleVal * 100 : doubleVal
            return Int(min(100, max(0, pct)))
        }
        return nil
    }

    // ISO8601DateFormatter is documented thread-safe; nonisolated(unsafe)
    // lets the nonisolated parse helpers (used by ModelScopedLimit's init)
    // share the cached instances.
    private nonisolated(unsafe) static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoFormatterStandard = ISO8601DateFormatter()

    private nonisolated static func parseISO8601(_ isoString: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: isoString) { return date }
        return isoFormatterStandard.date(from: isoString)
    }
}
