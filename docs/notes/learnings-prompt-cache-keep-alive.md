# Learnings: Prompt-cache keep-alive

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`. Cost figures are on `KeepAliveCoordinator`'s type doc.

- **Decline while a permission request or AskUserQuestion is pending** — the refresh would be submitted as the user's answer.
- **An elapsed `sessionResetDate` counts as a fresh quota window** — quota only moves on API traffic, so the ceiling would otherwise latch all night.
- **Never decline on staleness past the TTL** — `lastActivityAt` only advances on API traffic, so one long sleep would disable the feature permanently.
- **Decline on a measured 5m window** (`KeepAliveGate.observedTTL`, read from `usage.cache_creation` by `ShimProcess.trackCacheWindow`); measured 1h permits. Before the first reading a caller-supplied provider is declined. `ShimProcess.sessionUsesCustomEndpoint` must read the inherited `ANTHROPIC_BASE_URL` too, not just the UI setting.
- **Never run with a recap in flight** — both `*IneligibilityReason` functions name the other as a gate.
- **A failed `result` is not a refresh** (`keepAliveResultFailed`). Do not retry early: the latch is clear and keep-alive frames skip `trackWorkingState`, so a retry becomes one real turn per 60 s tick against a standing 429.
- **Stamp the window at request start** (submission and each main `message_start`), not at `result`.
- **Swallow nothing until `keepAliveEchoSeen`** — a keep-alive reply has no marker; otherwise a dropped injection eats the next real turn's `result` and `isWorking` sticks.
- **"Swallow" means skip the trackers, not hide from the webview** — the webview needs the frames for its cache countdown. `keepAliveFrameForWebView` reshapes them (echo `isSynthetic`, no `stream_event`s, `assistant` keeps `usage` with empty `content`). Hiding turns with injected JS fails: the extension re-uses turn DOM nodes.
- **One refresh emits `command_lifecycle` ×2, `system/init`, `system/status` before the echo**, so the latch alone must cover those; `system/status` stays passed through.
- **Clear the latch in `resetActivityState()`** — otherwise a reconnected session's first real turn is misread as ours.
- **Filter refreshes from replay and titles:** `strippingKeepAliveArtifacts` and `ClaudeSessionHistory`'s skip list.
- **`KeepAliveGate.promptPrefix` is a published interface** — an out-of-repo `Stop` hook (Pager) matches it, and the CLI fires `Stop` before Canopy can swallow anything. Do not reword it.
- **A probe expectation must not reuse the implementation's expression** (see `sessionUsesCustomEndpoint` fixtures).
