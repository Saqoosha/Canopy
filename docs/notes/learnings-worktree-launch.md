# Learnings: Worktree launch

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Send the first prompt only from the `launch_claude` intercept in `ShimProcess`.** Do NOT wait for the CLI's `system/init` (on a fresh session the CLI emits only `system/hook_*` until it gets a turn, so the wait deadlocks; `cliResolvedModel` likewise stays empty until the first turn). Do NOT send it from the `channelId` backstop: since extension 2.1.280 the webview sends a channel-scoped request before `launch_claude` and the extension drops the prompt (`Channel not found`) while Canopy logs `submitted`.
- **Keep "sent" state on `OpenSession.pendingInitialPrompt`, not on `ShimProcess`** — a reconnect builds a new `ShimProcess` and would resubmit.
- **The branch name and session title come from one call; the title is settled, never regenerated** (`settledTitle` → `OpenSession.pendingSettledTitle` → `ShimProcess.maybeGenerateTitle`). Two calls word the same task differently.
- **The naming call's only defence against prompt injection is its system prompt**; `--allowed-tools ''` removes nothing (see `SessionTitleGenerator.arguments`). Test with an "ignore previous instructions" prompt: the call must name the task, not obey it.
- **A new worktree has no session history, so Continue silently starts fresh** — read `willContinueSession`, never write `continueSession` (persisted preference).
