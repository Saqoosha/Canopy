import Foundation
import Observation

@Observable
final class StatusBarData {
    var cliVersion: String = ""
    var model: String = ""
    var contextUsed: Int = 0
    var contextMax: Int = 0
    var messageCount: Int = 0
    var gitBranch: String = ""
    var vcsType: VCSType = .unknown
    var remoteHost: String?

    // Rate limits from usage_update (extension → webview, intercepted by ShimProcess)
    var sessionPct: Int = 0        // 5hr utilization 0-100
    var sessionResetDate: Date?    // actual reset time (re-formatted on each render)
    var weeklyPct: Int = 0         // 7-day utilization 0-100
    var weeklyResetDate: Date?     // actual reset time
    var weeklyPctSonnet: Int = 0   // 7-day Sonnet-only utilization 0-100
    var weeklyResetDateSonnet: Date?  // actual reset time for Sonnet-only limit

    // Compact boundary indicator
    var didCompact: Bool = false

    enum VCSType { case unknown, git, jj }

    /// Effective context window for compaction purposes (matches CC's auto-compact: effectiveWindow = contextMax - 8000).
    private static let compactionBuffer = 8_000
    var compactionWindow: Int {
        let effective = contextMax - Self.compactionBuffer
        return effective > 0 ? effective : contextMax
    }

    var contextPct: Int {
        let window = compactionWindow
        guard window > 0 else { return 0 }
        return min(100, contextUsed * 100 / window)
    }

    /// Weekly limit to display: Sonnet-only when using Sonnet and data available, otherwise all-models.
    var effectiveWeeklyPct: Int {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyPctSonnet : weeklyPct
    }

    var effectiveWeeklyResetDate: Date? {
        model.lowercased().contains("sonnet") && weeklyResetDateSonnet != nil ? weeklyResetDateSonnet : weeklyResetDate
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func resetContext() {
        contextUsed = 0
        didCompact = true
    }

    func clearCompactIndicator() {
        didCompact = false
    }

    /// Reset all data for a new session.
    func resetAll() {
        cliVersion = ""
        model = ""
        contextUsed = 0
        contextMax = 0
        messageCount = 0
        gitBranch = ""
        vcsType = .unknown
        sessionPct = 0
        sessionResetDate = nil
        weeklyPct = 0
        weeklyResetDate = nil
        weeklyPctSonnet = 0
        weeklyResetDateSonnet = nil
        didCompact = false
        remoteHost = nil
    }

    /// Parse usage_update utilization from extension
    func updateRateLimits(_ utilization: [String: Any]) {
        if let entry = utilization["fiveHour"] as? [String: Any] {
            sessionPct = entry["utilization"].map { StatusBarData.parseUtilization($0) } ?? 0
            sessionResetDate = (entry["resetsAt"] as? String).flatMap { StatusBarData.parseISO8601($0) }
        }
        if let entry = utilization["sevenDay"] as? [String: Any] {
            weeklyPct = entry["utilization"].map { StatusBarData.parseUtilization($0) } ?? 0
            weeklyResetDate = (entry["resetsAt"] as? String).flatMap { StatusBarData.parseISO8601($0) }
        }
        if let sevenDaySonnet = utilization["sevenDaySonnet"] as? [String: Any] {
            weeklyPctSonnet = sevenDaySonnet["utilization"].map { StatusBarData.parseUtilization($0) } ?? 0
            weeklyResetDateSonnet = (sevenDaySonnet["resetsAt"] as? String).flatMap { StatusBarData.parseISO8601($0) }
        } else {
            weeklyPctSonnet = 0
            weeklyResetDateSonnet = nil
        }
    }

    /// Parse utilization value: API may send as 0-1 fraction (Double) or 0-100 percentage (Int).
    /// Int values are treated as percentages. Double <= 1.0 as fractions.
    private static func parseUtilization(_ value: Any) -> Int {
        if let intVal = value as? Int {
            return min(100, max(0, intVal))
        } else if let doubleVal = value as? Double {
            let pct = doubleVal <= 1.0 ? doubleVal * 100 : doubleVal
            return Int(min(100, max(0, pct)))
        }
        return 0
    }

    /// Parse ISO8601 date string (with or without fractional seconds).
    private static func parseISO8601(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        return ISO8601DateFormatter().date(from: isoString)
    }

    /// Format reset Date as relative string: "18m", "2h05m", "4d", "soon"
    static func formatResetTime(_ date: Date?) -> String {
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
}
