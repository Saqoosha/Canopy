import Foundation

/// `JobSnapshot` on the two wires: the control protocol's `session_state` row
/// (`[String: Any]`) and the roster's Codable JSON. Times are whole unix
/// seconds on both, so the phone can format them with its own clock.
extension JobSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case label, done, total, etaAt, state, stalledSince, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        done = try c.decode(Int.self, forKey: .done)
        total = try c.decode(Int.self, forKey: .total)
        etaAt = try c.decodeIfPresent(Int.self, forKey: .etaAt).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        state = try c.decode(JobState.self, forKey: .state)
        stalledSince = try c.decodeIfPresent(Int.self, forKey: .stalledSince).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(done, forKey: .done)
        try c.encode(total, forKey: .total)
        try c.encodeIfPresent(etaAt.map { Int($0.timeIntervalSince1970) }, forKey: .etaAt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(stalledSince.map { Int($0.timeIntervalSince1970) }, forKey: .stalledSince)
        try c.encodeIfPresent(note, forKey: .note)
    }

    var wire: [String: Any] {
        var dict: [String: Any] = ["label": label, "done": done, "total": total, "state": state.rawValue]
        if let etaAt { dict["etaAt"] = Int(etaAt.timeIntervalSince1970) }
        if let stalledSince { dict["stalledSince"] = Int(stalledSince.timeIntervalSince1970) }
        if let note { dict["note"] = note }
        return dict
    }

    init?(wire: [String: Any]) {
        guard let label = wire["label"] as? String, let done = wire["done"] as? Int,
              let total = wire["total"] as? Int,
              let state = (wire["state"] as? String).flatMap(JobState.init(rawValue:)) else { return nil }
        let time = { (key: String) in (wire[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        self.init(label: label, done: done, total: total, etaAt: time("etaAt"), state: state,
                  stalledSince: time("stalledSince"), note: wire["note"] as? String)
    }
}
