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
    /// - Parameter resumeId: the CLI's own session id, which survives a
    ///   Canopy restart. The phone groups a session's history by it; without
    ///   it every restart orphans everything stored so far.
    /// - Parameter answerable: false for an ask that Allow/Deny cannot
    ///   resolve — an `AskUserQuestion`, whose answer is text the model asked
    ///   for. The phone then shows the ask without buttons rather than
    ///   offering two that cannot work.
    /// - Parameter choices: an `AskUserQuestion`'s questions and their option
    ///   labels, from `AskUserQuestionForm.choices(from:)`. Present exactly
    ///   when `answerable` is false, and for the same reason inverted: the
    ///   ask cannot be answered with Allow/Deny, but it CAN be answered by
    ///   picking one of these. Without it the phone rendered the tool input
    ///   as raw JSON with a plain text field under it — the question legible
    ///   and unanswerable, which is the state the push exists to end.
    /// - Parameter bodyFull: the untruncated text. `body` is the BANNER —
    ///   short by necessity, and the phone stores this one for the
    ///   conversation.
    ///
    ///   **Not sending it capped the conversation at the banner's length**,
    ///   which is measured in BYTES: 2400 of them is about 800 characters of
    ///   Japanese, so a long message arrived cut to roughly a third with an
    ///   ellipsis and no way to see the rest (reported from the device
    ///   2026-09-05). The relay has accepted this field since the push was
    ///   built; only this side never filled it in.
    ///
    ///   It is not unbounded on the other side either — the relay caps it at
    ///   3000 code points and then shrinks the whole payload to fit APNs's
    ///   4 KB, which is the real ceiling and cannot be raised from here.
    static func post(kind: Kind, sessionId: String, resumeId: String? = nil,
                     title: String, body: String, bodyFull: String? = nil,
                     requestId: String? = nil, allowAlways: Bool = false,
                     answerable: Bool = true,
                     choices: [[String: Any]]? = nil) {
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
        if let bodyFull, !bodyFull.isEmpty, bodyFull != body {
            payload["bodyFull"] = bodyFull
        }
        if let resumeId, !resumeId.isEmpty {
            payload["resumeId"] = resumeId
        }
        if let requestId {
            payload["requestId"] = requestId
            payload["allowAlways"] = allowAlways
            payload["answerable"] = answerable
            if let choices, !choices.isEmpty {
                payload["choices"] = choices
            }
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
