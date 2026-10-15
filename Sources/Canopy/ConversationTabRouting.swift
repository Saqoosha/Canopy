import Foundation

/// Turns the CC webview's "open in a new tab" requests into Canopy panes.
///
/// The webview forks a conversation in place unless the host reports
/// `openNewInTab`, which the extension sets only for an editor panel. With it
/// on, a fork (and a new conversation) arrives as `new_conversation_tab`, which
/// the extension would answer by building a hidden panel inside the shim. The
/// flag also makes the webview send `rename_tab`, which Canopy's title handling
/// must not start seeing. So a pane that opts in forces the flag on frames into
/// the page and answers both requests itself, before they reach the session.
enum ConversationTabRouting {
    struct NewTab: Equatable {
        let requestId: String
        /// The forked session; nil for a fresh conversation.
        let sessionId: String?
        /// Text for the new conversation's composer, not sent.
        let initialPrompt: String?
    }

    /// Request kinds answered here and never forwarded.
    static let answeredKinds: Set<String> = ["new_conversation_tab", "rename_tab"]

    /// `frame` with `openNewInTab` set on the host state it carries
    /// (`init_response`, `update_state`), or `frame` unchanged.
    static func patchingOpenNewInTab(_ frame: [String: Any]) -> [String: Any] {
        guard frame["type"] as? String == "from-extension",
              var message = frame["message"] as? [String: Any] else { return frame }
        let key: String
        switch message["type"] as? String {
        case "response": key = "response"
        case "request": key = "request"
        default: return frame
        }
        guard var body = message[key] as? [String: Any],
              ["init_response", "update_state"].contains(body["type"] as? String ?? ""),
              var state = body["state"] as? [String: Any] else { return frame }
        state["openNewInTab"] = true
        body["state"] = state
        message[key] = body
        var out = frame
        out["message"] = message
        return out
    }

    /// The kind and id of a webview→host request answered here, or nil.
    static func answeredRequest(_ dict: [String: Any]) -> (kind: String, requestId: String)? {
        guard dict["type"] as? String == "request",
              let requestId = dict["requestId"] as? String,
              let kind = (dict["request"] as? [String: Any])?["type"] as? String,
              answeredKinds.contains(kind) else { return nil }
        return (kind, requestId)
    }

    /// A `new_conversation_tab` request, or nil.
    static func newTab(_ dict: [String: Any]) -> NewTab? {
        guard let (kind, requestId) = answeredRequest(dict), kind == "new_conversation_tab",
              let request = dict["request"] as? [String: Any] else { return nil }
        let sessionId = (request["sessionId"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let prompt = (request["initialPrompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return NewTab(requestId: requestId, sessionId: sessionId, initialPrompt: prompt)
    }

    /// The frame that answers request `requestId` of `kind`, as the extension would.
    static func response(kind: String, requestId: String) -> [String: Any] {
        ["type": "from-extension",
         "message": ["type": "response", "requestId": requestId,
                     "response": ["type": kind + "_response"]] as [String: Any]]
    }
}
