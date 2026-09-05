import Foundation

/// The `AskUserQuestion` tool's input, and what a valid answer to it looks
/// like.
///
/// **Every rule here was read out of the extension's own webview bundle**
/// (`webview/index.js`) rather than designed. Measured against **2.1.260**,
/// the version Canopy actually loads — from its own managed directory under
/// `~/Library/Application Support/Canopy/extensions`, NOT from
/// `~/.vscode/extensions`, which on this machine held only far older copies
/// and is what a first pass mistakenly read. The same shape is also present
/// in 2.1.90, so it has held across 170 releases; the minified component name
/// has not (`h30` there, `Lj0` here), which is why none is cited.
///
/// The shape that matters is the answer map:
///
///     $.answers[question.question]  →  "Label A, Label B"
///
/// keyed by the question's TEXT, valued by the chosen option labels joined
/// with `", "` — the extension splits on exactly that separator when it
/// restores a partially-filled form. Answering therefore is not a reply and
/// not a bare allow: it is the permission request's own `allow`, carrying an
/// `updatedInput` that is the original input with `answers` filled in. That is
/// why `ShimProcess.applyPermissionDecision` used to refuse these outright —
/// echoing the input back unchanged resolves the request with the QUESTION,
/// and the tool never receives what it asked for.
///
/// Pure, so the probe can exercise it without a shim, a socket or a phone.
enum AskUserQuestionForm {
    /// The separator the extension joins and splits answer labels on.
    static let labelSeparator = ", "

    /// What the phone needs to draw the form: one entry per question, each
    /// with its option labels.
    ///
    /// Returns nil when the input is not an AskUserQuestion form at all, so a
    /// caller can tell "no questions" from "an empty question list" — the
    /// second would draw a card with no buttons, which is the state this
    /// whole change exists to remove.
    static func choices(from inputs: Any?) -> [[String: Any]]? {
        guard let dict = inputs as? [String: Any],
              let questions = dict["questions"] as? [[String: Any]],
              !questions.isEmpty
        else { return nil }
        var out: [[String: Any]] = []
        for question in questions {
            guard let text = question["question"] as? String, !text.isEmpty,
                  let options = question["options"] as? [[String: Any]]
            else { return nil }
            let labels = options.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
            guard !labels.isEmpty else { return nil }
            var entry: [String: Any] = ["question": text, "options": labels]
            if let header = question["header"] as? String, !header.isEmpty {
                entry["header"] = header
            }
            entry["multiSelect"] = question["multiSelect"] as? Bool ?? false
            out.append(entry)
        }
        return out
    }

    /// The `updatedInput` for an answered form, or nil if the answer does not
    /// resolve the question that was asked.
    ///
    /// **Strict on purpose.** The phone draws buttons from `choices(from:)`,
    /// so a well-behaved client can only send labels that were offered; a
    /// client that sends anything else is either out of date or not the
    /// phone, and resolving the request with a label the model never listed
    /// would put words in the user's mouth on their own machine. Every
    /// question must be answered, every label must be one that was offered,
    /// and a single-select question takes exactly one.
    ///
    /// The extension's "Other" free-text escape is deliberately NOT accepted:
    /// it needs a text field the phone does not draw, and accepting arbitrary
    /// text here would defeat the paragraph above. Answering "Other" stays a
    /// thing you do at the Mac.
    static func merged(inputs: Any?, answers: [String: String]) -> [String: Any]? {
        guard !answers.isEmpty,
              let dict = inputs as? [String: Any],
              let questions = dict["questions"] as? [[String: Any]],
              !questions.isEmpty
        else { return nil }
        var accepted: [String: String] = [:]
        for question in questions {
            guard let text = question["question"] as? String,
                  let options = question["options"] as? [[String: Any]],
                  let answer = answers[text]
            else { return nil }
            let offered = Set(options.compactMap { $0["label"] as? String })
            // **An offered label may itself contain the separator.** These
            // are model-authored ("Save, then quit"), and the format cannot
            // represent one unambiguously — the extension joins on ", " and
            // splits on ", " too, so the ambiguity is the format's, not this
            // parser's. Resolve it the only way that cannot be wrong: if the
            // WHOLE answer is a label that was offered, it is that one label.
            // Splitting first refused a perfectly valid single-select answer
            // and left the ask pending on the Mac with nothing to explain it.
            let chosen: [String]
            if offered.contains(answer) {
                chosen = [answer]
            } else {
                chosen = answer.components(separatedBy: labelSeparator)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            guard !chosen.isEmpty, chosen.allSatisfy({ offered.contains($0) }) else { return nil }
            let multiSelect = question["multiSelect"] as? Bool ?? false
            guard multiSelect || chosen.count == 1 else { return nil }
            // Re-joined from the parsed labels rather than passed through, so
            // stray whitespace in a client's string cannot reach the
            // extension's own `split(", ")` and produce a label with a space
            // on it that matches nothing.
            accepted[text] = chosen.joined(separator: labelSeparator)
        }
        // Answers naming a question that was not asked mean the phone is
        // answering a DIFFERENT form — a stale card for a request that has
        // since been replaced. Refuse rather than silently dropping the
        // extra: the ones that did match are then just as likely to be stale.
        guard accepted.count == answers.count else { return nil }
        var updated = dict
        updated["answers"] = accepted
        return updated
    }
}
