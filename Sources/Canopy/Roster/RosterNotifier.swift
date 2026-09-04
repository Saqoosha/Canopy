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

    static func post(kind: Kind, sessionId: String, title: String, body: String) {
        let settings = CanopySettings.shared
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return }
        components.path = "/notify"
        // Refuse anything but https, mirroring `RosterPublisher.connectIfConfigured()`
        // (CWE-319, PR #177): this call builds the same Bearer-secret request
        // by a second door, so an http:// endpoint would reopen the exact
        // cleartext-secret hole that guard was added to close.
        guard components.scheme == "https" else {
            logger.error("roster endpoint must be https; refusing to send the secret over \(components.scheme ?? "no scheme", privacy: .public)")
            return
        }
        guard let url = components.url,
              let secret = RosterPublisher.sharedSecretForNotifier()
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "machine": machineId,
            "sessionId": sessionId,
            "title": title,
            "body": body,
            "kind": kind.rawValue,
        ])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.notice("roster notify failed: \(error.localizedDescription, privacy: .public)")
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                logger.notice("roster notify returned \(code, privacy: .public)")
            }
        }.resume()
    }
}
