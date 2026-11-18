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
        requestText(toolName: toolName, inputs: inputs).flatMap(firstLine)
    }

    private static func requestText(toolName: String, inputs: Any?) -> String? {
        let dict = inputs as? [String: Any] ?? [:]
        if toolName == "AskUserQuestion",
           let questions = dict["questions"] as? [[String: Any]],
           let question = (questions.first?["question"] as? String).flatMap(uncappedFirstLine) {
            return question
        }
        if toolName == "Bash" {
            if let description = (dict["description"] as? String).flatMap(uncappedFirstLine) {
                return "Bash: \(description)"
            }
            if let command = (dict["command"] as? String).flatMap(uncappedFirstLine) {
                return "Bash: \(command)"
            }
        }
        if let path = (dict["file_path"] ?? dict["notebook_path"]) as? String, !path.isEmpty {
            return "\(toolName): \((path as NSString).lastPathComponent)"
        }
        return toolName.isEmpty ? nil : toolName
    }

    /// A finished turn: the first line of the model's last message outside a
    /// code block that still has text once its leading heading, list, task or
    /// quote markers and every `**` are removed.
    static func forTurnEnd(finalText: String?) -> String? {
        guard let finalText else { return nil }
        var inFence = false
        for raw in finalText.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let text = firstLine(unmarked(line)) else { continue }
            return text
        }
        return nil
    }

    private static func unmarked(_ line: String) -> String {
        var out = line.replacingOccurrences(of: "**", with: "")
        while true {
            let next = out
                .replacingOccurrences(of: #"^(#{1,6}|>|[-*+]|\d+\.|\[[ xX]\])(\s+|$)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-*_]{3,}$"#, with: "", options: .regularExpression)
            if next == out { return out }
            out = next
        }
    }

    /// First non-blank line, trimmed and cut to `maxCharacters`.
    static func firstLine(_ text: String) -> String? {
        guard let line = uncappedFirstLine(text) else { return nil }
        return line.count > maxCharacters ? String(line.prefix(maxCharacters - 1)) + "…" : line
    }

    private static func uncappedFirstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
