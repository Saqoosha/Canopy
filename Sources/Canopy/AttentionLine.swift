import Foundation

/// Builds `OpenSession.attentionLine`: one plain line for a sidebar row,
/// never Markdown or JSON. Pure, so the probe can pin every shape.
enum AttentionLine {
    /// Longer lines are cut here with an ellipsis; the row truncates again to
    /// its width, so this only bounds what crosses the control socket.
    static let maxCharacters = 120

    /// A permission request or AskUserQuestion. The first question for
    /// AskUserQuestion, Bash's description (else its command's first line),
    /// a file tool's file name, and otherwise the tool name alone.
    static func forRequest(toolName: String, inputs: Any?) -> String? {
        let dict = inputs as? [String: Any] ?? [:]
        if toolName == "AskUserQuestion",
           let questions = dict["questions"] as? [[String: Any]],
           let question = questions.first?["question"] as? String,
           let line = clipped(question) {
            return line
        }
        if toolName == "Bash" {
            if let description = dict["description"] as? String, let line = clipped(description) {
                return "Bash: \(line)"
            }
            if let command = dict["command"] as? String, let line = clipped(command) {
                return "Bash: \(line)"
            }
        }
        if let path = (dict["file_path"] ?? dict["notebook_path"]) as? String, !path.isEmpty {
            return "\(toolName): \((path as NSString).lastPathComponent)"
        }
        return toolName.isEmpty ? nil : toolName
    }

    /// A finished turn: the first non-blank line of the model's last message.
    static func forTurnEnd(finalText: String?) -> String? {
        finalText.flatMap(clipped)
    }

    /// First non-blank line, leading Markdown heading/list/quote marks and
    /// emphasis asterisks removed, cut to `maxCharacters`.
    static func clipped(_ text: String) -> String? {
        guard let raw = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var line = raw.replacingOccurrences(of: "**", with: "")
        while let first = line.first, "#>-*".contains(first) {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return nil }
        return line.count > maxCharacters ? String(line.prefix(maxCharacters - 1)) + "…" : line
    }
}
