import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Roster")

/// Posts one notification event to the relay, which fans it to APNs.
///
/// Deliberately fire-and-forget and stateless: a dropped notification is a
/// missed buzz, and the roster's live socket already carries the same state
/// change, so nothing here is worth a retry queue.
@MainActor
enum RosterNotifier {
    enum Kind: String { case completed, asking }

    /// Every guard `post` needs before it can actually send, minus the
    /// network call itself — pulled out so `willPost` and `post` read from
    /// one place and can't drift apart. `nil` means "would not send."
    private static func resolvedTarget() -> (machineId: String, url: URL, secret: String)? {
        let settings = CanopySettings.shared
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return nil }
        components.path = "/notify"
        // Refuse anything but https, mirroring `RosterPublisher.connectIfConfigured()`
        // (CWE-319, PR #177): this call builds the same Bearer-secret request
        // by a second door, so an http:// endpoint would reopen the exact
        // cleartext-secret hole that guard was added to close.
        guard components.scheme == "https" else {
            logger.error("roster endpoint must be https; refusing to send the secret over \(components.scheme ?? "no scheme", privacy: .public)")
            return nil
        }
        guard let url = components.url,
              let secret = RosterPublisher.sharedSecretForNotifier()
        else { return nil }
        return (machineId, url, secret)
    }

    /// True exactly when `post` would attempt to send. `ShimProcess` reads
    /// this to decide whether to export `CANOPY_PANE` — see that call site's
    /// doc for why the two must not disagree.
    static var willPost: Bool { resolvedTarget() != nil }

    /// - Parameter requestId: carried only by `.asking` pushes, so a later
    ///   Allow/Deny reply from the phone has something to answer. The relay
    ///   requires it on an `.asking` push, rejects it on a `.completed` one,
    ///   and forwards it into the APNs payload, where the notification
    ///   category's Allow/Deny actions send it back to `POST /decide`.
    /// - Parameter allowAlways: whether the CLI proposed a rule for this ask.
    ///   Sent so the phone can offer "Always" only when there is something to
    ///   write — a button that silently degrades to a plain Allow would tell
    ///   the user they had made a standing decision they had not.
    static func post(kind: Kind, sessionId: String, title: String, body: String,
                     requestId: String? = nil, allowAlways: Bool = false) {
        guard let (machineId, url, secret) = resolvedTarget() else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "machine": machineId,
            "sessionId": sessionId,
            "title": title,
            "body": body,
            "kind": kind.rawValue,
        ]
        if let requestId {
            payload["requestId"] = requestId
            payload["allowAlways"] = allowAlways
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.notice("roster notify failed: \(error.localizedDescription, privacy: .public)")
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                logger.notice("roster notify returned \(code, privacy: .public)")
            }
        }.resume()
    }
}
