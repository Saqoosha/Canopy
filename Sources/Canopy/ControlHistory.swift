import Foundation

/// One turn as `history` reports it.
nonisolated struct ControlHistoryTurn: Equatable, Sendable {
    /// Nil for a turn no person started (the model answering a task notification).
    var prompt: String?
    var reply: String
    var addressedTo: String?
    /// The prompt record's `timestamp`, as the CLI wrote it.
    var at: String?

    var wire: [String: Any] {
        var out: [String: Any] = ["reply": reply]
        if let prompt { out["prompt"] = prompt }
        if let addressedTo { out["addressedTo"] = addressedTo }
        if let at { out["at"] = at }
        return out
    }
}

/// The conversation read back from a session's transcript, so turns typed in
/// a pane or on the phone are there as well as control turns.
nonisolated enum ControlHistory {
    /// Turns that START inside `text` (whole JSONL lines), oldest first.
    /// Subagent records, keep-alive refreshes and their replies are left out.
    static func turns(inJSONL text: String) -> [ControlHistoryTurn] {
        var turns: [ControlHistoryTurn] = []
        var current: (prompt: String?, at: String?, blocks: [String])?
        var hidden = false
        func close() {
            if let turn = current, turn.prompt != nil || !turn.blocks.isEmpty {
                let reply = ControlEvent.turnReply(blocks: turn.blocks, result: turn.blocks.last ?? "")
                turns.append(ControlHistoryTurn(prompt: turn.prompt, reply: reply.text,
                                                addressedTo: reply.addressedTo, at: turn.at))
            }
            current = nil
        }
        for line in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["isSidechain"] as? Bool != true, json["parent_tool_use_id"] as? String == nil else { continue }
            if let kind = ClaudeSessionHistory.classifyUserRecord(json) {
                switch kind {
                case .continuation: continue
                case .keepAlive:
                    close()
                    hidden = true
                case .prompt(let prompt):
                    close()
                    hidden = false
                    current = (prompt, json["timestamp"] as? String, [])
                case .other:
                    close()
                    hidden = false
                    current = (nil, json["timestamp"] as? String, [])
                }
                continue
            }
            guard json["type"] as? String == "assistant", !hidden,
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            current?.blocks.append(contentsOf: texts)
        }
        close()
        return turns
    }

    /// The last `limit` turns of the transcript at `path`. Reads a tail window
    /// and widens it until it holds that many turns or the whole file.
    static func read(path: String, limit: Int) -> [ControlHistoryTurn]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var window: UInt64 = 1 << 20
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            // A window that starts mid-file starts mid-line; that partial line is dropped.
            if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            let found = turns(inJSONL: text)
            if found.count >= limit || start == 0 || window >= maxWindow { return Array(found.suffix(limit)) }
            window *= 4
        }
    }

    static let maxWindow: UInt64 = 64 << 20
    static let defaultLimit = 10
    static let maxLimit = 50
}
