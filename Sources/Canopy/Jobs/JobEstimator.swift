import Foundation

/// One reading of a job's probe.
struct JobSample: Codable, Equatable {
    let at: Date
    let done: Int
    let total: Int
}

enum JobState: String, Codable, Hashable {
    /// Fewer than two readings with different counts: no rate yet, so no time.
    case measuring
    case running
    /// The count has not moved for the stall threshold.
    case stalled
    /// The probe failed `JobEstimator.failureLimit` times in a row.
    case unknown
    case done
}

/// What the row and the phone show for a job.
struct JobSnapshot: Hashable {
    let label: String
    let done: Int
    let total: Int
    /// Finish time; nil unless `state == .running`.
    let etaAt: Date?
    let state: JobState
    /// When the count last moved; set only while `state == .stalled`.
    let stalledSince: Date?
    /// Why a reading is missing, shown on hover (e.g. "ssh の認証に失敗"). Set by `JobWatcher`.
    var note: String? = nil
}

/// Turns probe output into a count, and a run of counts into a finish time.
/// Pure, so the probe can pin every rule in the spec's 計測 section.
enum JobEstimator {
    static let failureLimit = 3
    /// Larger counts are not readings: they would overflow the finish time's unix seconds.
    static let maxCount = 1_000_000_000
    static let windowMinutes: Double = 15
    static let stallFloorMinutes: Double = 15
    static let stallMedianFactor: Double = 3
    /// Until two moves give a time per unit to scale by, a stall
    /// needs this long without a move: one epoch of a slow training run can take 20 min.
    static let firstUnitStallMinutes: Double = 60

    /// The last `N/M` in `output`, or with a known `total`, the last integer.
    /// Nil when the output holds no number: a failed reading, never `done = 0`.
    static func parse(_ output: String, total: Int?) -> (done: Int, total: Int)? {
        if let total {
            guard let match = output.matches(of: /\d+/).last, let done = Int(match.output),
                  done <= maxCount, (1...maxCount).contains(total) else { return nil }
            return (done, total)
        }
        guard let match = output.matches(of: /(\d+)\s*\/\s*(\d+)/).last,
              let done = Int(match.output.1), let total = Int(match.output.2),
              done <= maxCount, (1...maxCount).contains(total) else { return nil }
        return (done, total)
    }

    /// `previous` is the state the last reading produced: a failed reading keeps a stall,
    /// and never creates one.
    static func evaluate(label: String, samples: [JobSample], failures: Int,
                         now: Date, stallMinutes: Double?, previous: JobState? = nil) -> JobSnapshot {
        let current = sinceLastRestart(samples)
        guard let last = current.last else {
            return JobSnapshot(label: label, done: 0, total: 0, etaAt: nil,
                               state: failures >= failureLimit ? .unknown : .measuring, stalledSince: nil)
        }
        func snapshot(_ state: JobState, eta: Date? = nil, stalledSince: Date? = nil) -> JobSnapshot {
            JobSnapshot(label: label, done: last.done, total: last.total, etaAt: eta,
                        state: state, stalledSince: stalledSince)
        }
        if failures >= failureLimit { return snapshot(.unknown) }
        if last.total > 0 && last.done >= last.total { return snapshot(.done) }

        // The first reading is where watching began, not a move: a job registered late in a
        // unit moves soon after, and that gap says nothing about the time per unit.
        let points = changePoints(current)
        let moves = Array(points.dropFirst())
        let lastChange = points.last!
        let gaps = zip(moves, moves.dropFirst()).map { $1.at.timeIntervalSince($0.at) / 60 }
        let threshold = stallMinutes
            ?? (gaps.isEmpty ? firstUnitStallMinutes : max(stallFloorMinutes, stallMedianFactor * median(gaps)!))
        // Only a reading that saw the count unchanged may call a stall; a failed one keeps it.
        let unmoved = now.timeIntervalSince(lastChange.at) >= threshold * 60
        if unmoved && (failures == 0 || previous == .stalled) {
            return snapshot(.stalled, stalledSince: lastChange.at)
        }
        guard moves.count >= 2 else { return snapshot(.measuring) }

        // Moves in the last 15 min, or the last two when fewer fall inside.
        var window = moves.filter { now.timeIntervalSince($0.at) <= windowMinutes * 60 }
        if window.count < 2 { window = Array(moves.suffix(2)) }
        let first = window.first!, end = window.last!
        let rate = Double(end.done - first.done) / end.at.timeIntervalSince(first.at)
        guard rate > 0 else { return snapshot(.measuring) }
        // From now, so the time is never in the past.
        return snapshot(.running, eta: now.addingTimeInterval(Double(end.total - end.done) / rate))
    }

    /// Readings after the last restart: a count that went down or a total that changed
    /// starts a new run, since its earlier readings say nothing about this one's rate.
    private static func sinceLastRestart(_ samples: [JobSample]) -> ArraySlice<JobSample> {
        var start = samples.startIndex
        for i in samples.indices.dropFirst() {
            let prev = samples[i - 1], cur = samples[i]
            if cur.done < prev.done || cur.total != prev.total { start = i }
        }
        return samples[start...]
    }

    /// The first reading, then each reading whose count differs from the one before.
    private static func changePoints(_ samples: ArraySlice<JobSample>) -> [JobSample] {
        var points: [JobSample] = []
        for s in samples where points.last?.done != s.done { points.append(s) }
        return points
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
