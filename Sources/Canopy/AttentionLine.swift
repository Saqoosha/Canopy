import Foundation

/// Builds `OpenSession.attentionLine`: one line for a sidebar row.
enum AttentionLine {
    /// Longer lines are cut here with an ellipsis.
    static let maxCharacters = 120

    /// A permission request or AskUserQuestion. The first question for
    /// AskUserQuestion, Bash's description (else its command's first line),
    /// a file tool's file name, and otherwise the tool name alone. Shown as
    /// written: this is what the user is approving.
    static func forRequest(toolName: String, inputs: Any?) -> String? {
        let dict = inputs as? [String: Any] ?? [:]
        if toolName == "AskUserQuestion",
           let questions = dict["questions"] as? [[String: Any]],
           let question = questions.first?["question"] as? String,
           let line = firstLine(question) {
            return line
        }
        if toolName == "Bash" {
            if let description = dict["description"] as? String, let line = firstLine(description) {
                return "Bash: \(line)"
            }
            if let command = dict["command"] as? String, let line = firstLine(command) {
                return "Bash: \(line)"
            }
        }
        if let path = (dict["file_path"] ?? dict["notebook_path"]) as? String, !path.isEmpty {
            return "\(toolName): \((path as NSString).lastPathComponent)"
        }
        return toolName.isEmpty ? nil : toolName
    }

    /// A finished turn: the first line of the model's last message that is
    /// not blank or a code fence, with a leading heading, list or quote
    /// marker and every `**` removed.
    static func forTurnEnd(finalText: String?) -> String? {
        guard let finalText else { return nil }
        let line = finalText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }
        guard let line else { return nil }
        let unmarked = line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"^(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        return firstLine(unmarked)
    }

    /// First non-blank line, trimmed and cut to `maxCharacters`.
    static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return line.count > maxCharacters ? String(line.prefix(maxCharacters - 1)) + "…" : line
    }
}
