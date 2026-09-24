import Foundation
import Observation

/// The status bar under a session, as one NDJSON line for a mirror client that asked for it
/// with `"status": true` on its attach. Sent once after `attach_ok`, then after every change.
///
/// Two readings of the meter ride on one line, for two clients:
/// - Display-ready (`contextWindow`, `contextPct`, `contextLevel`) for the phone. The
///   percentage and level come from the CLI's thresholds, which live in `StatusBarData` with
///   the reasoning that produced them; a phone handed the raw numbers would carry a second
///   copy of that arithmetic and drift from it at the next CLI release.
/// - Raw (`contextMax`, `maxOutputTokens`, `contextUsed`) for another Mac's mirror pane, whose
///   `StatusBarData` is the same type and recomputes the rest itself (`apply(_:to:)`).
///
/// No model or message count: the phone does not draw them (its page's composer names the
/// model), and the roster already carries both for the Mac pane.
enum MirrorStatusFrame {
    static func payload(from data: StatusBarData) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "status",
            "branch": data.gitBranch,
            "vcs": vcsName(data.vcsType),
            "contextUsed": data.contextUsed,
            "contextMax": data.contextMax,
            "maxOutputTokens": data.maxOutputTokens,
            // `contextWindow` falls back to `contextMax` and is 0 exactly when the Mac hides the meter.
            "contextWindow": data.compactionWindow,
            "contextPct": data.contextPct,
            "contextLevel": levelName(data.contextLevel),
            "didCompact": data.didCompact,
        ]
        if let remote = data.remoteHost { payload["remoteHost"] = remote }
        return payload
    }

    /// Writes the raw fields of a received line into a mirror pane's `StatusBarData`, which then
    /// reads as the origin's bar does on the same Canopy version. `model` and `messageCount` are
    /// the roster's and are left alone; a line without the raw fields changes nothing.
    static func apply(_ frame: [String: Any], to data: StatusBarData) {
        guard frame["type"] as? String == "status",
              let used = frame["contextUsed"] as? Int,
              let max = frame["contextMax"] as? Int,
              let output = frame["maxOutputTokens"] as? Int
        else { return }
        data.contextUsed = used
        data.contextMax = max
        data.maxOutputTokens = output
        data.gitBranch = frame["branch"] as? String ?? ""
        data.vcsType = vcsType(frame["vcs"] as? String ?? "")
        data.didCompact = frame["didCompact"] as? Bool ?? false
        data.remoteHost = frame["remoteHost"] as? String
    }

    private static func vcsType(_ name: String) -> StatusBarData.VCSType {
        switch name {
        case "git": .git
        case "jj": .jj
        default: .unknown
        }
    }

    private static func vcsName(_ type: StatusBarData.VCSType) -> String {
        switch type {
        case .git: "git"
        case .jj: "jj"
        case .unknown: ""
        }
    }

    private static func levelName(_ level: StatusBarData.ContextLevel) -> String {
        switch level {
        case .unknown: "unknown"
        case .ok: "ok"
        case .warn: "warn"
        case .compact: "compact"
        case .blocked: "blocked"
        }
    }
}

/// Sends `MirrorStatusFrame` to one sink for as long as `stop()` has not been called.
///
/// `withObservationTracking` fires `onChange` once, on the first mutation after it was armed,
/// and stays quiet until re-armed; the re-arm happens on the next main-actor turn, so a burst
/// of synchronous writes (`resetContext` sets two fields) becomes one line.
@MainActor
final class MirrorStatusPublisher {
    private let data: StatusBarData
    private let send: ([String: Any]) -> Void
    private var lastSent: Data?
    private var stopped = false

    init(data: StatusBarData, send: @escaping ([String: Any]) -> Void) {
        self.data = data
        self.send = send
    }

    func start() {
        publish()
    }

    func stop() {
        stopped = true
    }

    private func publish() {
        guard !stopped else { return }
        let payload = withObservationTracking {
            MirrorStatusFrame.payload(from: data)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.publish() }
        }
        // Unchanged after a write to a field the frame reads the same way (a compact that
        // lands on an already-zero count, say) — nothing for the client to redraw.
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              encoded != lastSent
        else { return }
        lastSent = encoded
        send(payload)
    }
}

/// The session's Claude account usage, as one NDJSON line for a Mac mirror client that asked
/// with `"usage": true` on its attach: `{"type":"usage","email":…,"rate_limits":{…}}`, where
/// `rate_limits` is the raw `/api/oauth/usage` shape so the client parses it with the same
/// `RateLimitAccount.updateFromRawUsage` a shim's `get_usage` reply goes through. The phone
/// never asks.
enum MirrorUsageFrame {
    static func payload(email: String, rateLimits: [String: Any]) -> [String: Any] {
        ["type": "usage", "email": email, "rate_limits": rateLimits]
    }

    /// The record a received line is filed under on this Mac: nil when the origin runs as this
    /// Mac's own account, whose numbers this Mac already fetches itself.
    static func key(forFrame frame: [String: Any], localEmail: String?) -> RateLimitAccount.Key? {
        guard frame["type"] as? String == "usage",
              let email = frame["email"] as? String, !email.isEmpty,
              frame["rate_limits"] is [String: Any]
        else { return nil }
        return ShimProcess.rateLimitKey(remoteEmail: email, localEmail: localEmail, host: "")
    }
}

/// Sends `MirrorUsageFrame` for one shim's account to one sink, on attach and on every change.
///
/// The shim's binding can still be unresolved at attach (an SSH remote session or a non-default
/// login reads its `.claude.json` first), and `ShimProcess` is not observable, so that wait is
/// polled for at most two minutes. Everything after it is observed.
@MainActor
final class MirrorUsagePublisher {
    private weak var shim: ShimProcess?
    private let send: ([String: Any]) -> Void
    private var lastSent: Data?
    private var stopped = false
    private var resolveRetries = 0
    private static let resolveRetryInterval: TimeInterval = 5
    private static let maxResolveRetries = 24

    init(shim: ShimProcess, send: @escaping ([String: Any]) -> Void) {
        self.shim = shim
        self.send = send
    }

    func start() {
        publish()
    }

    func stop() {
        stopped = true
    }

    private func publish() {
        guard !stopped, let shim else { return }
        guard shim.rateLimitAccount != nil else {
            guard resolveRetries < Self.maxResolveRetries else { return }
            resolveRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveRetryInterval) { [weak self] in
                MainActor.assumeIsolated { self?.publish() }
            }
            return
        }
        // Everything is read inside the tracked pass, the numbers before the email, so an email
        // that becomes known later (a folded host key, a `.claude.json` read) goes out with the next update.
        let payload = withObservationTracking { () -> [String: Any]? in
            guard let rateLimits = shim.rateLimitAccount?.rawUsagePayload(),
                  let email = shim.rateLimitEmail
            else { return nil }
            return MirrorUsageFrame.payload(email: email, rateLimits: rateLimits)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.publish() }
        }
        guard let payload else { return }
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              encoded != lastSent
        else { return }
        lastSent = encoded
        send(payload)
    }
}
