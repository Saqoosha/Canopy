import Foundation

/// How a job looks on a sidebar row. A display-level override only: it never
/// writes back to `SessionActivity`, so the Dock badge, the MacroPad and the
/// roster's `state` keep their meaning (spec: 行の状態).
enum JobDisplay {
    /// The finish time, or `明日 H:mm` when it falls on a later day.
    static func timeLabel(_ eta: Date, now: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: eta)
        let m = calendar.component(.minute, from: eta)
        let clock = String(format: "%d:%02d", h, m)
        return calendar.isDate(eta, inSameDayAs: now) ? clock : "明日 \(clock)"
    }

    /// The row's right edge: top line, optional bottom line, and whether the top is red.
    static func trailing(_ job: JobSnapshot, now: Date, calendar: Calendar = .current)
        -> (top: String, bottom: String?, isAlert: Bool) {
        switch job.state {
        case .running:
            return (job.etaAt.map { timeLabel($0, now: now, calendar: calendar) } ?? "計測中", percent(job), false)
        case .measuring:
            return ("計測中", percent(job), false)
        case .stalled:
            return ("停止", job.stalledSince.map { ActivityClock.elapsed(since: $0, now: now) }, true)
        case .unknown:
            return ("—", nil, false)
        case .done:
            return ("完了", nil, false)
        }
    }

    static func help(_ job: JobSnapshot, now: Date) -> String {
        if let note = job.note { return "\(job.label) · \(note)" }
        let count = "\(job.label) \(job.done)/\(job.total)"
        switch job.state {
        case .running:
            guard let eta = job.etaAt else { return count }
            let minutes = max(0, Int((eta.timeIntervalSince(now) / 60).rounded()))
            return "\(count) · あと \(minutes) 分"
        case .measuring: return "\(count) · 計測中"
        case .stalled: return "\(job.label) \(stalledLine(job))"
        case .unknown: return "\(count) · 読めない"
        case .done: return "\(count) · 完了"
        }
    }

    static func stalledLine(_ job: JobSnapshot) -> String {
        "\(job.done)/\(job.total) で止まっている"
    }

    static func fraction(_ job: JobSnapshot) -> Double {
        job.total > 0 ? min(1, Double(job.done) / Double(job.total)) : 0
    }

    /// A finished job's ring goes away; the row falls back to the usual unread mark.
    static func drawsRing(_ job: JobSnapshot?) -> Bool {
        guard let job else { return false }
        return job.state != .done
    }

    /// The color the dot and ring are drawn in. A session that is asking or broken keeps
    /// its own color; a stall reads as error; a job running behind an idle session reads as
    /// background, since something is still running.
    static func ringActivity(_ activity: SessionActivity, job: JobSnapshot?) -> SessionActivity {
        guard let job, drawsRing(job) else { return activity }
        switch activity {
        case .asking, .error: return activity
        default: break
        }
        if job.state == .stalled { return .error }
        switch activity {
        case .idle, .unread, .empty: return .background
        default: return activity
        }
    }

    /// A stalled job moves its row into Needs you; nothing else changes the group.
    static func statusGroup(_ activity: SessionActivity, job: JobSnapshot?) -> SidebarStatusGroup {
        job?.state == .stalled ? .needsYou : SidebarStatusGroup.of(activity)
    }

    private static func percent(_ job: JobSnapshot) -> String? {
        job.total > 0 ? "\(Int(fraction(job) * 100))%" : nil
    }
}
