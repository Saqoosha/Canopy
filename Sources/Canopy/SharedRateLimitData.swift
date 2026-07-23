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
    /// value; watch `log show --predicate 'subsystem == "sh.saqoo.Canopy"
    /// AND category == "RateLimit"'` for `extractRawUsage`'s shape-mismatch
    /// warning in ShimProcess — that is the discovery signal for that
    /// failure. Persistent well-formed omission of the `model_scoped` key
    /// alone is detected separately (see `updateFromRawUsage`'s absence
    /// counter). Also: raw responses that arrive WITHOUT the `model_scoped`
    /// key deliberately keep the last value (see the semantics block in
    /// `updateFromRawUsage`); stale rows are hidden at render time by
    /// `SidebarAccountSection`'s resetDate filter once their reset time
    /// passes.
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
            // Match applyRawWindow's "malformed → keep previous" promise:
            // a stateless value type can't carry "previous", so instead of
            // silently synthesizing 0% (indistinguishable from a real
            // no-usage row) we drop the entry and log. The row disappears
            // for one tick; the next well-formed payload rebuilds it.
            guard let parsedPct = SharedRateLimitData.parseUtilizationStrict(json["utilization"]) else {
                logger.warning("model_scoped entry '\(name, privacy: .public)': unparseable utilization (\(String(describing: json["utilization"]), privacy: .public)); dropping row")
                return nil
            }
            displayName = name
            pct = parsedPct
            if let iso = json["resets_at"] as? String {
                if let parsedDate = SharedRateLimitData.parseISO8601(iso) {
                    resetDate = parsedDate
                } else {
                    logger.warning("model_scoped entry '\(name, privacy: .public)': unparseable resets_at '\(iso, privacy: .public)'; treating as nil")
                    resetDate = nil
                }
            } else {
                resetDate = nil
            }
        }

        /// SidebarAccountSection's render-time filter. Hides rows whose
        /// weekly window has already elapsed — the "keep previous on
        /// absent" branch in `updateFromRawUsage` intentionally leaves
        /// dropped-by-server buckets in place, and this is the mechanism
        /// that lets them fall off once their reset date passes.
        var isFresh: Bool {
            guard let resetDate else { return true }
            return resetDate > Date()
        }
    }

    var modelScoped: [ModelScopedLimit] = []

    /// Counter for consecutive `updateFromRawUsage` ticks in which the
    /// payload was well-formed but simply lacked the `model_scoped` key.
    /// Warns once when the streak crosses the threshold so a persistent
    /// server-side drop (as opposed to the intermittent transient the
    /// "absent → keep previous" branch is tuned for) is discoverable.
    /// Reset by any tick where model_scoped is present in any form.
    private var consecutiveModelScopedAbsences: Int = 0
    private static let modelScopedAbsenceWarnThreshold = 10

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
        // five_hour and seven_day: always-present windows for authenticated
        // accounts. If the outer type ever drifts (server ships a null or
        // wrong shape) the bars silently keep their last value forever with
        // no discoverable signal — warn on wrong-type so the drift is
        // findable via the RateLimit log category.
        if let entry = rateLimits["five_hour"] as? [String: Any] {
            applyRawWindow(entry, label: "five_hour", pct: &sessionPct, reset: &sessionResetDate)
        } else if let value = rateLimits["five_hour"], !(value is NSNull) {
            logger.warning("raw usage five_hour: unexpected type (\(String(describing: value), privacy: .public)); keeping previous")
        }
        if let entry = rateLimits["seven_day"] as? [String: Any] {
            applyRawWindow(entry, label: "seven_day", pct: &weeklyPct, reset: &weeklyResetDate)
        } else if let value = rateLimits["seven_day"], !(value is NSNull) {
            logger.warning("raw usage seven_day: unexpected type (\(String(describing: value), privacy: .public)); keeping previous")
        }
        // seven_day_sonnet: absent OR explicit null both mean "account no
        // longer has this bucket" — clear so the two update paths (raw +
        // extension transform) don't disagree based on response ordering.
        // A wrong-type payload is a schema drift signal, not a plan change:
        // keep previous and warn instead of masking the drift as a plan
        // downgrade.
        if let entry = rateLimits["seven_day_sonnet"] as? [String: Any] {
            applyRawWindow(entry, label: "seven_day_sonnet", pct: &weeklyPctSonnet, reset: &weeklyResetDateSonnet)
        } else if let value = rateLimits["seven_day_sonnet"], !(value is NSNull) {
            logger.warning("raw usage seven_day_sonnet: unexpected type (\(String(describing: value), privacy: .public)); keeping previous")
        } else {
            weeklyPctSonnet = 0
            weeklyResetDateSonnet = nil
        }
        // model_scoped semantics differ from the 5hr/weekly/sonnet windows.
        // Anthropic's `/api/oauth/usage` has been observed omitting the
        // `model_scoped` key on some responses even when per-model usage
        // is unchanged; the old "absent → wipe" branch made the per-model
        // rows (e.g. Weekly Fable) flicker in and out on every ~60s tick.
        // Treat absent as "unknown, keep previous" rather than "empty" and
        // rely on `SidebarAccountSection`'s render-time resetDate filter to
        // hide stale rows once their reset window elapses.
        //   - present as [[String: Any]] → apply (may clear on [])
        //   - present as NSNull → clear (server says "no per-model data")
        //   - absent → keep previous (bump absence counter; see below)
        //   - present as some other type → keep previous + warn
        if let scoped = rateLimits["model_scoped"] as? [[String: Any]] {
            consecutiveModelScopedAbsences = 0
            let parsed = scoped.compactMap { ModelScopedLimit(json: $0) }
            // If any entry was dropped by `ModelScopedLimit.init?` (each
            // dropped row already logged its own reason), treat the whole
            // array as malformed and keep previous state rather than
            // partially overwriting. Two failure modes this guards against:
            //   1. All entries invalid → `compactMap` returns [] → without
            //      this guard, would clear modelScoped as if the server
            //      had sent an explicit empty array (semantically wrong —
            //      an all-invalid non-empty array is NOT "server says
            //      empty", it's payload corruption).
            //   2. Some valid + some invalid → without this guard, the
            //      previously-fresh state for the invalid rows would be
            //      overwritten with only the valid subset, silently
            //      dropping known-good buckets.
            guard parsed.count == scoped.count else {
                logger.warning("raw usage model_scoped: \(scoped.count - parsed.count, privacy: .public) of \(scoped.count, privacy: .public) entries malformed; keeping previous")
                return
            }
            // Dedupe on displayName (the ForEach identity) — server-owned
            // values carry no uniqueness guarantee, and duplicate IDs are
            // undefined behavior for SwiftUI's ForEach.
            var seen = Set<String>()
            modelScoped = parsed.filter { seen.insert($0.displayName).inserted }
        } else if rateLimits["model_scoped"] is NSNull {
            modelScoped = []
            consecutiveModelScopedAbsences = 0
        } else if rateLimits["model_scoped"] != nil {
            logger.warning("raw usage model_scoped: unexpected type (\(String(describing: rateLimits["model_scoped"]), privacy: .public)); keeping previous")
            consecutiveModelScopedAbsences = 0
        } else {
            // Absent from an otherwise well-formed payload. Anti-flicker
            // branch — but a persistent server-side drop would freeze
            // per-model rows with no discoverable trace. `== threshold`
            // (not `>=`) so the warning fires exactly once per streak.
            consecutiveModelScopedAbsences += 1
            if consecutiveModelScopedAbsences == Self.modelScopedAbsenceWarnThreshold {
                logger.warning("raw usage model_scoped: absent for \(Self.modelScopedAbsenceWarnThreshold, privacy: .public) consecutive updates (~\(Self.modelScopedAbsenceWarnThreshold, privacy: .public)min at 60s throttle); per-model rows may be stale")
            }
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
