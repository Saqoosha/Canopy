import Foundation

/// One row in the native subagent activity list — mirrors what the Claude
/// Code CLI renders at the bottom of the terminal while Agent tool calls run.
struct SubagentInfo: Identifiable, Equatable {
    let id: String // Agent tool_use block id
    let agentType: String // input.subagent_type, e.g. "coderabbit:code-reviewer"
    let label: String // input.description, e.g. "CodeRabbit review"
    let startedAt: Date
    var finishedAt: Date?
    /// Latest observed context size of the subagent (input + cache_creation +
    /// cache_read + output of its most recent assistant message). Grows as
    /// the subagent works, same as the "↓ Nk tokens" column in the CLI.
    var tokens: Int = 0

    var isRunning: Bool { finishedAt == nil }

    func elapsed(now: Date) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Maintains the subagent rows for the current turn from the CLI io_message
/// stream. All the data the CLI's terminal task list shows is already in the
/// stream Canopy forwards to the webview:
///
/// - launch:   assistant message (no parent_tool_use_id) containing `Agent`
///             tool_use blocks — input has `description` + `subagent_type`
/// - progress: subagent assistant messages arrive with `parent_tool_use_id`
///             set to the launching tool_use id; their `usage` gives tokens
/// - done:     user message with a matching `tool_result` block
/// - new turn: a real user prompt (no tool_result blocks) clears the list
///
/// Pure value type so `_SidebarLogicProbe` can exercise it without spawning
/// a shim.
struct SubagentTracker {
    private(set) var rows: [SubagentInfo] = []

    /// Set when a `result` ends the turn. The CLI does not reliably echo the
    /// user's next typed prompt back as a `user` io_message (those are mostly
    /// tool_result messages), so the robust "new turn" signal is the first
    /// main-conversation `message_start` after a `result` — clear the
    /// previous turn's rows there.
    private var turnEnded = false

    /// Feed one io_message dict (`{type:"assistant"|"user"|"result", ...}`).
    /// Returns true when `rows` changed.
    mutating func observe(_ ioMsg: [String: Any], now: Date) -> Bool {
        switch ioMsg["type"] as? String {
        case "assistant":
            if let parent = ioMsg["parent_tool_use_id"] as? String {
                return updateTokens(parentId: parent, ioMsg: ioMsg)
            }
            return addLaunches(ioMsg: ioMsg, now: now)

        case "user":
            // Subagent-side user messages (tool results inside the child
            // conversation) also stream through with parent_tool_use_id set —
            // they must neither complete rows nor clear the list.
            if ioMsg["parent_tool_use_id"] is String { return false }
            return handleUserMessage(ioMsg: ioMsg, now: now)

        case "result":
            // Turn ended — freeze anything still marked running (user pressed
            // Stop, or a background agent's tool_result never came back this
            // turn). A stuck spinner is worse than an early "done".
            turnEnded = true
            var changed = false
            for i in rows.indices where rows[i].finishedAt == nil {
                rows[i].finishedAt = now
                changed = true
            }
            return changed

        case "stream_event":
            // First main-conversation message_start after a result = new turn.
            // Subagent stream_events carry parent_tool_use_id — ignore those.
            guard turnEnded,
                  !(ioMsg["parent_tool_use_id"] is String),
                  let event = ioMsg["event"] as? [String: Any],
                  event["type"] as? String == "message_start"
            else { return false }
            turnEnded = false
            guard !rows.isEmpty else { return false }
            rows = []
            return true

        default:
            return false
        }
    }

    /// Register `Agent` tool_use blocks from a main-conversation assistant
    /// message. Only the final assistant message carries a populated `input`
    /// (stream_event content_block_start has it empty — input arrives over
    /// input_json_delta), so that's the one we key off, same as
    /// `detectBackgroundTaskLaunch`.
    private mutating func addLaunches(ioMsg: [String: Any], now: Date) -> Bool {
        guard let msg = ioMsg["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]]
        else { return false }
        var changed = false
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String,
                  name == "Agent" || name == "Task", // "Task" = pre-rename CLIs
                  let id = block["id"] as? String,
                  !rows.contains(where: { $0.id == id })
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            rows.append(SubagentInfo(
                id: id,
                agentType: input["subagent_type"] as? String ?? "agent",
                label: input["description"] as? String ?? "Agent task",
                startedAt: now
            ))
            changed = true
        }
        return changed
    }

    private mutating func updateTokens(parentId: String, ioMsg: [String: Any]) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.id == parentId }),
              let msg = ioMsg["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else { return false }
        let total = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["output_tokens"] as? Int ?? 0)
        // Context only grows within a subagent; ignore out-of-order updates.
        guard total > rows[idx].tokens else { return false }
        rows[idx].tokens = total
        return true
    }

    private mutating func handleUserMessage(ioMsg: [String: Any], now: Date) -> Bool {
        guard let msg = ioMsg["message"] as? [String: Any] else { return false }
        // Tool results come back as a content array; a real user prompt is a
        // plain string (or a content array with no tool_result blocks).
        if let content = msg["content"] as? [[String: Any]] {
            var sawToolResult = false
            var changed = false
            for block in content {
                guard block["type"] as? String == "tool_result" else { continue }
                sawToolResult = true
                if let id = block["tool_use_id"] as? String,
                   let idx = rows.firstIndex(where: { $0.id == id }),
                   rows[idx].finishedAt == nil {
                    rows[idx].finishedAt = now
                    changed = true
                }
            }
            if sawToolResult { return changed }
        }
        // A real user prompt starts a new turn — drop the previous turn's rows.
        turnEnded = false
        guard !rows.isEmpty else { return false }
        rows = []
        return true
    }
}
