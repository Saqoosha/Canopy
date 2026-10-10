# Learnings: Background-task reconcile

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Only a `wake` may bulk-clear (`BackgroundReconcileTrigger.allowsBulkClear`)** — the idle pass must not, or it wipes the hourglass ~15 s after launch on SSH sessions whose JSONL is unreachable.
- **Match on every byte read; advance the offset only past whole lines** — otherwise a partial line strands half a marker, or a whole marker in an unterminated tail is dropped.
- **Do not use `max(existing, endOffset)` for scan offsets** — the file can be replaced and the end legitimately lands lower; `max` strands the id.
- **Launch acks have two wordings** (Bash `Command running in background with ID:`; Agent `Async agent launched successfully.…agentId:`) — a single-prefix parser silently drops Agents. The retired `Spawned successfully.\nagent_id:` form is deliberately unhandled.
- **Open gap:** `isBackgroundLaunchBlock` requires `run_in_background: true`, so some async-agent launches are never tracked. Do not just widen it — a misclassified launch gets an hourglass that never clears.
- **`[bg]` decision lines log at `notice`** (`info` is a short ring buffer); lines with paths use `privacy: .private`.
