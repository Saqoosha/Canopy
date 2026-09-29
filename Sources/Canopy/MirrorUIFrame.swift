import AppKit

/// UI a daemon session asks its Mac client to show, because the daemon has no
/// pane of its own: a file or output in `ContentViewer`, the recap row or an
/// error banner in the pane's page, an alert, a notification. Data only: the
/// client builds any JavaScript itself, so a host cannot run code in its page.
/// Sent only to a client whose attach said `"ui": true`; an older Mac would
/// post the frames into its page and never answer an alert.
enum MirrorUIFrame: Equatable {
    case showContent(title: String, content: String, startLine: Int?, endLine: Int?)
    /// Nil clears the row.
    case recap(String?)
    case errorBanner(String)
    case alert(requestId: String, message: String, severity: String, buttons: [String])
    case notify(title: String, body: String)

    static let type = "canopy_ui"

    /// Largest `showContent` text sent inline. The client drops a connection on a
    /// line over `NDJSONLineBuffer.maxLineBytes` (16 MiB, counted after decompression),
    /// and JSON escaping can grow text up to 6× (a control character becomes `\u00XX`).
    static let maxInlineContentBytes = 2 << 20

    /// `content` cut to `maxInlineContentBytes` on a character boundary, with a note saying so.
    static func inlineContent(_ content: String) -> String {
        guard content.utf8.count > maxInlineContentBytes else { return content }
        var end = content.utf8.index(content.utf8.startIndex, offsetBy: maxInlineContentBytes)
        while end > content.startIndex, String.Index(end, within: content) == nil {
            end = content.utf8.index(before: end)
        }
        let mb = content.utf8.count >> 20
        return String(content[..<end]) + "\n\n… truncated (\(mb) MB in all)"
    }

    var wire: [String: Any] {
        var dict: [String: Any] = ["type": Self.type]
        switch self {
        case .showContent(let title, let content, let startLine, let endLine):
            dict["action"] = "show_content"
            dict["title"] = title
            dict["content"] = content
            if let startLine { dict["startLine"] = startLine }
            if let endLine { dict["endLine"] = endLine }
        case .recap(let text):
            dict["action"] = "recap"
            if let text { dict["text"] = text }
        case .errorBanner(let message):
            dict["action"] = "error_banner"
            dict["message"] = message
        case .alert(let requestId, let message, let severity, let buttons):
            dict["action"] = "alert"
            dict["requestId"] = requestId
            dict["message"] = message
            dict["severity"] = severity
            dict["buttons"] = buttons
        case .notify(let title, let body):
            dict["action"] = "notify"
            dict["title"] = title
            dict["body"] = body
        }
        return dict
    }

    init?(wire: [String: Any]) {
        guard wire["type"] as? String == Self.type else { return nil }
        switch wire["action"] as? String {
        case "show_content":
            self = .showContent(title: wire["title"] as? String ?? "", content: wire["content"] as? String ?? "",
                                startLine: wire["startLine"] as? Int, endLine: wire["endLine"] as? Int)
        case "recap":
            self = .recap(wire["text"] as? String)
        case "error_banner":
            guard let message = wire["message"] as? String else { return nil }
            self = .errorBanner(message)
        case "alert":
            guard let requestId = wire["requestId"] as? String else { return nil }
            self = .alert(requestId: requestId, message: wire["message"] as? String ?? "",
                          severity: wire["severity"] as? String ?? "info", buttons: wire["buttons"] as? [String] ?? [])
        case "notify":
            self = .notify(title: wire["title"] as? String ?? "Canopy", body: wire["body"] as? String ?? "")
        default:
            return nil
        }
    }
}

/// A Mac client's answer to `MirrorUIFrame.alert`; `button` nil is Dismiss.
struct MirrorUIAnswer: Equatable {
    let requestId: String
    let button: String?

    static let type = "canopy_ui_answer"

    var wire: [String: Any] {
        var dict: [String: Any] = ["type": Self.type, "requestId": requestId]
        if let button { dict["button"] = button }
        return dict
    }

    init(requestId: String, button: String?) {
        self.requestId = requestId
        self.button = button
    }

    init?(wire: [String: Any]) {
        guard wire["type"] as? String == Self.type, let requestId = wire["requestId"] as? String else { return nil }
        self.init(requestId: requestId, button: wire["button"] as? String)
    }
}

/// Alerts a daemon shim forwarded to a Mac client, until that client answers
/// or goes away. Without it an answer from any client resolves any prompt, and
/// a client that leaves mid-alert leaves the extension waiting out its timeout.
struct PendingUIAlerts<Client: Hashable> {
    private var entries: [String: (client: Client, buttons: [String])] = [:]

    enum Answer: Equatable {
        /// Forward this button (nil is Dismiss).
        case accept(String?)
        /// Not an alert this shim forwarded, or already answered.
        case unknown
        /// From a client the alert did not go to.
        case wrongClient
    }

    var isEmpty: Bool { entries.isEmpty }

    mutating func record(requestId: String, client: Client, buttons: [String]) {
        entries[requestId] = (client, buttons)
    }

    /// A button that was not offered is answered as Dismiss.
    mutating func answer(requestId: String, button: String?, from client: Client) -> Answer {
        guard let entry = entries[requestId] else { return .unknown }
        guard entry.client == client else { return .wrongClient }
        entries[requestId] = nil
        return .accept(button.flatMap { entry.buttons.contains($0) ? $0 : nil })
    }

    /// The alerts that went to `client`, now owed a Dismiss.
    mutating func detach(_ client: Client) -> [String] {
        let ids = entries.filter { $0.value.client == client }.map(\.key).sorted()
        ids.forEach { entries[$0] = nil }
        return ids
    }
}

enum MirrorUIAlert {
    /// The button an `NSAlert` response names: `buttons` were added first, then Dismiss.
    static func button(response: Int, buttons: [String]) -> String? {
        let index = response - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? buttons[index] : nil
    }
}
