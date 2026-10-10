# Learnings: General

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`. Log, `@MainActor`, CLI-grep and DOM rules are in CLAUDE.md.

- **Use `--include-partial-messages`; never `--bare`** — the first yields `stream_event` SSE, the second skips keychain/OAuth.
- **Capture stream-json with the DEFAULT invocation first** (`echo hi | claude -p --output-format stream-json --verbose --include-partial-messages`), also with/without env vars Canopy sets — a fix verified only with `--model` failed on the default path.
- **Match the main model's `modelUsage` entry by exact name from `init.model` (`ShimProcess.cliResolvedModel`), not `StatusBarData.model`** — with no `--model`, `init`/`modelUsage` say `claude-opus-4-8[1m]` but `message_start` says the bare id, so matching on it never hits.
- **No `parent_tool_use_id` guard on the `stream_event` branch of `extractStatusData`** — the CLI never stamps it there, and a guard would silently freeze the meter if it ever did.
- **A byte window over a JSONL must be a line window** — a record can exceed any window and a cut record reads as "no user line" (no `sdk-*` filter, "Untitled"). `ClaudeSessionHistory.extractMetadata` reads whole records and escalates until a `type:"user"` record parses; drop partial lines, never parse them. `loadUserPrompts` is still a flat window.
- **Session loaders see only UUID-named files two levels deep** — `subagents/` and `agent-*.jsonl` are invisible.
- **EPIPE discriminator** — a dead stdin reader throws NSCocoa 512 wrapping POSIX 32; a write racing our own `stop()` throws 512 with no underlying error, so check the POSIX code (`writeToStdin`).
- **Do not add a process-wide `SIG_IGN` for SIGPIPE** — it silences every write in the app (it does not leak to `Process` children).
- **A tap gesture on a List row kills `.onMove` dragging** — `Sidebar.swift` uses a `List(selection:)` binding that always reads `nil` whose setter is the click handler.
- **"No sessions yet." with JSONLs on disk means a missing TCC Documents grant** — `tccutil reset SystemPolicyDocumentsFolder sh.saqoo.Canopy.debug`, then Allow.
- **For "catch every X" install both local and global NSEvent monitors** — each sees only its own destination; local closures must `return event`. Reference: `DragCursorLock.installInterruptSafety`.
- **Never `DispatchQueue.main.async` from `deinit`** — use `MainActor.assumeIsolated` as in `DragCursorLock`; the async gap lets a successor take effect first.
