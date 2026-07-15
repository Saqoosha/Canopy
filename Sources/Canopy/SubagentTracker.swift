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
    /// `input.run_in_background == true` at launch. Bg Agent's initial
    /// `tool_result` is just an ack ("Command running in background with
    /// ID: bXX"), NOT completion — the real completion goes to the JSONL
    /// as a `<task-notification>` that the CLI does not re-emit through
    /// io_message. Rows with this flag therefore don't finish on
    /// `tool_result`; they stay running until the turn's `result` freezes
    /// everything. Foreground rows (the common case) finish on
    /// `tool_result` as usual.
    let runInBackground: Bool

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

    /// `toolu_…` ids the CLI already logged before this shim spawned. On
    /// `--resume`, historic `Agent`/`Task` tool_use blocks are re-emitted
    /// through the io_message stream and would otherwise appear as fresh
    /// running rows in the activity list. ShimProcess populates this after
    /// the async JSONL scan completes (see `historicToolUseIds` there);
    /// while the set is still loading, historic launches may briefly show
    /// as live — same bounded-flicker trade-off documented on the shim's
    /// snapshot.
    var historicToolUseIds: Set<String> = []

    /// Feed one io_message dict (`{type:"assistant"|"user"|"result"|"stream_event", ...}`).
    /// Returns true when `rows` changed. `stream_event` is load-bearing:
    /// its `message_start` after a `result` is the robust "new turn"
    /// clear signal (see `turnEnded` above).
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
            // Subagents run their own Agent-SDK loop and emit their own
            // `result` event tagged with `parent_tool_use_id`. Freezing
            // main-conversation rows on that would mark every sibling
            // subagent as done and trip `turnEnded`, causing the next
            // main-conversation `message_start` (still mid-turn) to wipe
            // the whole list. Only the untagged main-conversation `result`
            // ends the turn.
            guard !(ioMsg["parent_tool_use_id"] is String) else { return false }
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
                  !rows.contains(where: { $0.id == id }),
                  // Historic replay from `--resume`: the id was in the JSONL
                  // when the shim spawned, so this is the CLI re-emitting an
                  // already-completed (or abandoned) subagent, not a live
                  // launch. Skip — same reasoning as ShimProcess's
                  // `pendingBackgroundTaskIds` historic gate.
                  !historicToolUseIds.contains(id)
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            rows.append(SubagentInfo(
                id: id,
                // Empty-string metadata is treated as absent: a blank
                // 190pt column with just a spinner is worse UX than a
                // labelled placeholder.
                agentType: nonEmpty(input["subagent_type"]) ?? "agent",
                label: nonEmpty(input["description"]) ?? "Agent task",
                startedAt: now,
                runInBackground: input["run_in_background"] as? Bool == true
            ))
            changed = true
        }
        return changed
    }

    /// Drop any row whose id is in `historicToolUseIds`. Returns the
    /// number purged. Called after the async historic-id snapshot lands
    /// so replays that raced ahead of the loader (added as "live" rows
    /// before the gate was populated) get removed instead of sticking
    /// as ghosts.
    mutating func purgeHistoric() -> Int {
        guard !historicToolUseIds.isEmpty, !rows.isEmpty else { return 0 }
        let before = rows.count
        rows.removeAll { historicToolUseIds.contains($0.id) }
        return before - rows.count
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
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
        // Two well-known shapes:
        //   1. `content: [[...tool_result blocks...]]` — CLI feeding tool
        //      results back to Claude. Match each to a row and finish it
        //      (except bg rows — their initial tool_result is an ack).
        //   2. `content: "some prompt"` (String) — the user actually typed
        //      something, so drop the previous turn's rows.
        // Anything else (empty content array, single dict wrapper, missing
        // content) is malformed by our contract; preserving rows is safer
        // than clearing them silently, and a legitimate CLI shape drift
        // shouldn't wipe the visible activity list.
        if let content = msg["content"] as? [[String: Any]] {
            var changed = false
            for block in content {
                guard block["type"] as? String == "tool_result" else { continue }
                if let id = block["tool_use_id"] as? String,
                   let idx = rows.firstIndex(where: { $0.id == id }),
                   rows[idx].finishedAt == nil,
                   // Bg Agent's initial `tool_result` is an ack ("Command
                   // running in background with ID: bXX"), not completion —
                   // the real end signal is a `<task-notification>` that
                   // never flows through io_message. Leave bg rows running
                   // until the turn's `result` freezes them.
                   !rows[idx].runInBackground
                {
                    rows[idx].finishedAt = now
                    changed = true
                }
            }
            return changed
        }
        // A real user prompt starts a new turn — drop the previous turn's rows.
        guard msg["content"] is String else { return false }
        turnEnded = false
        guard !rows.isEmpty else { return false }
        rows = []
        return true
    }
}
