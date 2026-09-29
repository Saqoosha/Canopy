import Foundation

/// UI a daemon session asks its Mac client to show, because the daemon has no
/// pane of its own: a file or output in `ContentViewer`, JavaScript for the
/// pane's page (recap, error banner), an alert, a notification.
enum MirrorUIFrame: Equatable {
    case showContent(title: String, content: String, startLine: Int?, endLine: Int?)
    case evalJS(String)
    case alert(requestId: String, message: String, severity: String, buttons: [String])
    case notify(title: String, body: String)

    static let type = "canopy_ui"

    var wire: [String: Any] {
        var dict: [String: Any] = ["type": Self.type]
        switch self {
        case .showContent(let title, let content, let startLine, let endLine):
            dict["action"] = "show_content"
            dict["title"] = title
            dict["content"] = content
            if let startLine { dict["startLine"] = startLine }
            if let endLine { dict["endLine"] = endLine }
        case .evalJS(let js):
            dict["action"] = "eval_js"
            dict["js"] = js
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
        case "eval_js":
            guard let js = wire["js"] as? String else { return nil }
            self = .evalJS(js)
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
