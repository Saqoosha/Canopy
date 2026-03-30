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

    // Rate limits from usage_update (extension → webview, intercepted by ShimProcess)
    var sessionPct: Int = 0       // 5hr utilization 0-100
    var sessionReset: String = "" // "18m", "2h05m"
    var weeklyPct: Int = 0        // 7-day utilization 0-100
    var weeklyReset: String = ""  // "4d"

    var contextPct: Int {
        guard contextMax > 0 else { return 0 }
        return min(100, contextUsed * 100 / contextMax)
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func resetContext() { contextUsed = 0 }

    /// Parse usage_update utilization from extension
    func updateRateLimits(_ utilization: [String: Any]) {
        if let fiveHour = utilization["fiveHour"] as? [String: Any] {
            if let u = fiveHour["utilization"] {
                sessionPct = StatusBarData.parseUtilization(u)
            }
            if let r = fiveHour["resetsAt"] as? String {
                sessionReset = formatResetTime(r)
            }
        }
        if let sevenDay = utilization["sevenDay"] as? [String: Any] {
            if let u = sevenDay["utilization"] {
                weeklyPct = StatusBarData.parseUtilization(u)
            }
            if let r = sevenDay["resetsAt"] as? String {
                weeklyReset = formatResetTime(r)
            }
        }
    }

    /// Parse utilization value: API may send as 0-1 fraction (Double) or 0-100 percentage (Int).
    /// Int values are treated as percentages. Double <= 1.0 as fractions.
    private static func parseUtilization(_ value: Any) -> Int {
        if let intVal = value as? Int {
            // Int: already a percentage (0-100)
            return min(100, max(0, intVal))
        } else if let doubleVal = value as? Double {
            // Double <= 1.0: 0-1 fraction; otherwise percentage
            let pct = doubleVal <= 1.0 ? doubleVal * 100 : doubleVal
            return Int(min(100, max(0, pct)))
        }
        return 0
    }

    /// Format ISO8601 reset time as relative string: "18m", "2h05m", "4d"
    private func formatResetTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString)
        else { return "" }

        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "soon" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainMinutes = minutes % 60
        if hours < 24 {
            return remainMinutes > 0 ? "\(hours)h\(String(format: "%02d", remainMinutes))m" : "\(hours)h"
        }
        return "\(hours / 24)d"
    }
}
