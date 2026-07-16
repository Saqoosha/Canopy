import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SubagentTracker")

/// One row in the native subagent activity list — mirrors what the Claude
/// Code CLI renders at the bottom of the terminal while Agent tool calls run.
struct SubagentInfo: Identifiable, Equatable {
    let id: String // Agent tool_use block id
    let agentType: String // input.subagent_type (e.g. "code-reviewer")
    let label: String // input.description (short human-readable task title)
    let startedAt: Date
    /// One-way: `nil` while running, set exactly once when the row finishes.
    /// Enforced by `finish(at:)` — external assignment isn't allowed so a
    /// stray re-set can't "un-finish" or move the completion earlier.
    private(set) var finishedAt: Date?
    /// Latest observed context size of the subagent (input + cache_creation +
    /// cache_read + output of its most recent assistant message). Grows as
    /// the subagent works, same as the "↓ Nk tokens" column in the CLI.
    /// Monotonic — enforced by `bumpTokens(to:)`.
    private(set) var tokens: Int = 0
    /// `input.run_in_background == true` at launch. Bg Agent's initial
    /// `tool_result` is just an ack ("Command running in background with
    /// ID: …"), NOT completion. The real completion arrives via one of
    /// two disjoint transports, both wired through
    /// `ShimProcess.completeIfPresent`:
    ///
    /// - **Natural completion**: written to the session JSONL as
    ///   `<tool-use-id>toolu_…</tool-use-id>`. The CLI does NOT re-emit
    ///   this through io_message, so `ShimProcess` picks it up on the
    ///   `isWorking: false→true` wake-up JSONL scan
    ///   (`clearCompletedBackgroundTasksOnWake` → `applyBgReconcile`).
    /// - **TaskStop kill**: does NOT write any JSONL `<tool-use-id>`
    ///   marker (verified against the MA-Whatsan session referenced in
    ///   `ShimProcess.bgTaskIdMap`'s docstring), but DOES flow through
    ///   io_message as an `assistant` `tool_use` block — caught by
    ///   `detectTaskStopLaunch` + the safety net in
    ///   `processUserToolResults`, both routing to `purgePendingByTaskId`.
    ///
    /// Rows with this flag therefore don't finish on `tool_result` and
    /// are also skipped by the turn's `result` freeze. Foreground rows
    /// (the common case) finish on `tool_result` as usual.
    let runInBackground: Bool

    var isRunning: Bool { finishedAt == nil }

    func elapsed(now: Date) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Empty-string metadata is treated as absent: a blank 190pt column with
    /// just a spinner is worse UX than a labelled placeholder. Centralised
    /// here so callers can pass raw dict values without pre-sanitising.
    init(id: String, agentType: String, label: String, startedAt: Date, runInBackground: Bool) {
        self.id = id
        self.agentType = agentType.isEmpty ? "agent" : agentType
        self.label = label.isEmpty ? "Agent task" : label
        self.startedAt = startedAt
        self.runInBackground = runInBackground
    }

    /// Mark the row done. Idempotent — re-calling on an already-finished row
    /// preserves the original completion time. The tracker relies on this
    /// so a subagent-side `result` (silently ignored) can't accidentally
    /// backdate a main-conversation row's `finishedAt`.
    mutating func finish(at date: Date) {
        if finishedAt == nil { finishedAt = date }
    }

    /// Monotonic token update. Ignores smaller totals so out-of-order streaming
    /// snapshots don't rewind the display. See `SubagentTracker.updateTokens`
    /// for the caller-side type-safety guard.
    mutating func bumpTokens(to newTotal: Int) {
        if newTotal > tokens { tokens = newTotal }
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
    /// previous turn's rows there. The rare case where the CLI *does*
    /// forward a typed prompt is handled defensively as a String-content
    /// backup in `handleUserMessage`.
    private var turnEnded = false

    /// `toolu_…` ids the CLI already logged before this shim spawned. On
    /// `--resume`, historic `Agent`/`Task` tool_use blocks are re-emitted
    /// through the io_message stream and would otherwise appear as fresh
    /// running rows in the activity list. ShimProcess populates this after
    /// the async JSONL scan completes via `loadHistoricIds(_:)` — that call
    /// atomically installs the set AND purges any rows that raced in as
    /// "live" while the loader was still running. Not writable by other
    /// callers so the fill-then-purge contract can't be split.
    private(set) var historicToolUseIds: Set<String> = []

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
            // Turn ended — freeze foreground rows still marked running
            // (user pressed Stop, or a tool_result never came back). Bg
            // rows (`runInBackground`) stay `isRunning` past this point:
            // their real completion comes from `completeIfPresent(id:at:)`
            // when ShimProcess observes a JSONL `<tool-use-id>` marker or
            // a TaskStop (see issue #91). `turnEnded` still flips so the
            // next-turn `message_start` can clear finished/foreground rows
            // while preserving running bg rows for the async wake path.
            turnEnded = true
            var changed = false
            for i in rows.indices where rows[i].finishedAt == nil && !rows[i].runInBackground {
                rows[i].finish(at: now)
                changed = true
            }
            return changed

        case "stream_event":
            // First main-conversation message_start after a result = new turn.
            // Subagent stream_events carry parent_tool_use_id — ignore those.
            // Foreground rows (and finished bg rows) still get cleared —
            // that's the visible per-turn reset users expect. Running bg
            // rows are exempted so a later async `completeIfPresent`
            // (triggered by JSONL `<tool-use-id>` marker via
            // `applyBgReconcile`, or by TaskStop via `purgePendingByTaskId`)
            // can find them and finish them properly. Without this
            // exemption, the async wake path structurally always loses a
            // race against the synchronous per-turn clear — the row gets
            // wiped on the same tick that fires the wake, before
            // `applyBgReconcile` lands on a later tick. Stuck-forever
            // backstop is now `ShimProcess`'s bulk-clear paths (no-JSONL /
            // read-failed), plus `resetActivityState()` on crash/reconnect.
            guard turnEnded,
                  !(ioMsg["parent_tool_use_id"] is String),
                  let event = ioMsg["event"] as? [String: Any],
                  event["type"] as? String == "message_start"
            else { return false }
            turnEnded = false
            guard !rows.isEmpty else { return false }
            let before = rows.count
            rows.removeAll { !($0.runInBackground && $0.isRunning) }
            return rows.count != before

        default:
            // Unknown io_message type — usually a CLI protocol extension we
            // don't model yet. Log at debug so a stream-format drift that
            // silently disables the activity list can be root-caused from
            // the unified log without spamming production.
            #if DEBUG
            let type = (ioMsg["type"] as? String) ?? "<missing>"
            logger.debug("observe: ignoring unknown io_message type=\(type, privacy: .public)")
            #endif
            return false
        }
    }

    /// Register `Agent` tool_use blocks from a main-conversation assistant
    /// message. Only the final assistant message carries a populated `input`
    /// (stream_event content_block_start has it empty — input arrives over
    /// input_json_delta), so that's the one we key off — same reasoning as
    /// `detectBackgroundTaskLaunch` uses for reading `input.run_in_background`.
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
                agentType: (input["subagent_type"] as? String) ?? "",
                label: (input["description"] as? String) ?? "",
                startedAt: now,
                runInBackground: input["run_in_background"] as? Bool == true
            ))
            changed = true
        }
        return changed
    }

    /// Atomically install the historic-id snapshot and purge any live rows
    /// that raced ahead of the loader. Callers get a single API to invoke
    /// in one go — the fill-then-purge sequencing can't be split, so we
    /// can't leak into a state where the set is populated but stale rows
    /// still sit in `rows`. Returns the number purged.
    @discardableResult
    mutating func loadHistoricIds(_ ids: Set<String>) -> Int {
        historicToolUseIds = ids
        return purgeHistoric()
    }

    /// Drop any row whose id is in `historicToolUseIds`. Returns the
    /// number purged. Also invoked by `loadHistoricIds(_:)` — kept
    /// separately so the probe can drive it independently of an install.
    mutating func purgeHistoric() -> Int {
        guard !historicToolUseIds.isEmpty, !rows.isEmpty else { return 0 }
        let before = rows.count
        rows.removeAll { historicToolUseIds.contains($0.id) }
        return before - rows.count
    }

    /// Finish the row for this launch id if it's currently running. Idempotent
    /// (reuses `finish(at:)`), so `ShimProcess` can call it from multiple
    /// completion signals — natural JSONL `<tool-use-id>` marker, TaskStop,
    /// or the init-time historic race-window reconcile — without needing to
    /// de-duplicate signals. Returns true when a row transitioned; the caller
    /// uses that to decide whether to refresh `statusBarData?.subagents`.
    ///
    /// No-op (returns false) for ids we never launched into `rows` —
    /// `ShimProcess`'s bulk paths pass every pending toolu id through here,
    /// but the tracker only observes `Agent` / `Task` tool_use blocks (bg
    /// Bash launches never enter `rows`, so their toolu ids no-op cleanly).
    /// Also returns false for Agent ids that already finished on a
    /// `tool_result` in the foreground path or via a prior signal. See
    /// issue #91.
    @discardableResult
    mutating func completeIfPresent(id: String, at date: Date) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.id == id && $0.finishedAt == nil })
        else { return false }
        rows[idx].finish(at: date)
        return true
    }

    private mutating func updateTokens(parentId: String, ioMsg: [String: Any]) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.id == parentId }),
              let msg = ioMsg["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else { return false }
        // Mandatory fields — if the CLI ever ships these as Doubles (JSON
        // number promotion) or renames them, the `?? 0` fallback in the
        // sum below would silently freeze tokens at 0 with no signal. A
        // strict guard here surfaces the drift in DEBUG builds without
        // making prod any less forgiving (still returns false).
        guard let inputTokens = usage["input_tokens"] as? Int,
              let outputTokens = usage["output_tokens"] as? Int
        else {
            #if DEBUG
            let keys = usage.keys.sorted().joined(separator: ",")
            logger.debug("updateTokens: usage type mismatch keys=\(keys, privacy: .public)")
            #endif
            return false
        }
        // cache_* fields are legitimately absent in early messages, so keep
        // the `?? 0` there. Present-but-wrong-type on those still degrades
        // to zero silently, which mirrors the CLI's own display behavior.
        let total = inputTokens
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + outputTokens
        // Context only grows within a subagent; ignore out-of-order updates.
        let before = rows[idx].tokens
        rows[idx].bumpTokens(to: total)
        return rows[idx].tokens != before
    }

    private mutating func handleUserMessage(ioMsg: [String: Any], now: Date) -> Bool {
        guard let msg = ioMsg["message"] as? [String: Any] else { return false }
        // Two well-known shapes:
        //   1. `content: [tool_result, tool_result, …]` — a JSON array of
        //      block dicts the CLI feeds back to Claude. Match each to a
        //      row and finish it (except bg rows — their initial tool_result
        //      is an ack, not completion).
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
                   // running in background with ID: …"), not completion —
                   // the real end signal never flows through this branch:
                   // natural completion goes to the JSONL and TaskStop goes
                   // to `detectTaskStopLaunch`; both route to
                   // `completeIfPresent`. Leave bg rows running.
                   !rows[idx].runInBackground
                {
                    rows[idx].finish(at: now)
                    changed = true
                }
            }
            return changed
        }
        // A real user prompt starts a new turn — drop the previous turn's rows.
        // Defensive backup path: the primary "new turn" signal is the
        // post-result `message_start` in the `stream_event` branch, since the
        // CLI usually replays user prompts as tool_result batches. This
        // String-content branch fires when the CLI does forward the typed
        // prompt as-is.
        guard msg["content"] is String else { return false }
        turnEnded = false
        guard !rows.isEmpty else { return false }
        rows = []
        return true
    }
}
