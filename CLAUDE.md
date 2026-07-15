# Canopy — Claude Code Extension Webview Host

## What Is This

macOS native app that hosts the Claude Code VSCode extension's webview (React UI) in a WKWebView. No VSCode required. The CC extension's bundled JS/CSS renders directly in a native macOS window with real-time streaming.

## Project Status: Fully Working (2026-04-29)

Full chat with Claude works via vscode-shim. **Single-window sidebar shell** (Arc/Chrome-style vertical tabs) — sessions live in a persistent left sidebar, the detail pane swaps the active WKWebView in place. Launcher row in the sidebar with directory picker, session history with instant replay, real auth, CLI process, real SSE streaming, tool use display, light theme matching VSCode, permission mode sync, slash commands, Sparkle auto-update, **SSH remote**, **Claude Code on the Web teleport**. Launcher includes model/effort/permission selectors.

**vscode-shim complete (Tasks 1-15)** — Node.js subprocess runs `extension.js` unmodified. 10 JS modules + Swift integration (ShimProcess, NodeDiscovery, Xcode bundling). Legacy handler removed.

**Sparkle auto-update** — SPM dependency, EdDSA-signed appcast on GitHub Pages, delta updates, embedded release notes from GitHub Releases.

**SSH remote** — Run Claude CLI on remote machines via SSH. Uses CC extension's `claudeProcessWrapper` setting with a bundled wrapper script. Remote directory browser via SSH.

## Tech Stack
- macOS 15.0+, Swift 6
- WKWebView hosting CC extension's React webview
- Node.js >= 18 (for vscode-shim, runs extension.js natively)
- Sparkle 2.9+ for auto-update
- xcodegen for project generation from `project.yml`
- Bundle ID: `sh.saqoo.Canopy`

## Build Commands
```bash
xcodegen generate
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Canopy.app
```

## Architecture

```
WKWebView ─── postMessage ──→ ShimProcess.swift (~600 lines)
                                  │ stdin/stdout NDJSON
                                  ▼
                              Node.js subprocess
                                  ├─ vscode-shim/ (10 JS modules, ~800 lines)
                                  │    └─ intercepts require("vscode")
                                  └─ extension.js (CC extension, unmodified)
                                       └─ spawns Claude CLI via child_process
```

SSH remote mode adds one layer: a wrapper script replaces the CLI spawn:

```
extension.js ─ child_process.spawn ──→ ssh-claude-wrapper.sh ──→ ssh -T host claude ...args
                                        (claudeProcessWrapper)     (remote CLI)
```

Runs extension.js as-is — no protocol reimplementation needed. Extension updates require zero Canopy code changes. See `docs/superpowers/specs/2026-03-29-vscode-shim-design.md` for full spec.

## Key Source Files

### Swift (Sources/Canopy/)
- `CanopyApp.swift` — SwiftUI app entry (single `WindowGroup` with `NavigationSplitView`), menu commands (Cmd+N new session, Cmd+W context-aware close session/window, Cmd+Shift+W close window, Cmd+0 show main window, Cmd+1..9 switch among open sessions, Cmd+O open folder), Sparkle updater, AppDelegate (close-button override, reopen handler, manual main-window frame save/restore via `canopy.mainWindowFrame` UserDefaults)
- `Sidebar.swift` — Left column List with Open + Recents sections, per-row icon (spawning spinner / asking yellow hand / thinking orange flower / waiting blue hourglass / idle dot for open rows; computer for closed local; cloud for closed cloud), filter gear popover, right-click "Hide from sidebar", AppKit-direct scroll-to-top via `ListScrollToTop`, `ThinkingFlower` TimelineView animating Unicode flower glyphs
- `Detail.swift` — Right pane: switches between `DetailLauncher` (when sidebar selection is `.launcher`) and `SessionContainer` (when `.session`); sets `.navigationTitle` (session title) + `.navigationSubtitle` (project)
- `SessionContainer.swift` — `WebViewContainer` + `ConnectionOverlayView` + `StatusBarView` + `SpawningOverlay`
- `SessionStore.swift` — `@Observable @MainActor` store: `openSessions` (insertion-ordered), `recents`, `cloud`, `filter`, `hiddenIds`, `selection`. Owns sidebar state, drives cloud polling (30 s) when sidebar visible, tracks `teleportingCloudId` so concurrent teleports serialize
- `OpenSession.swift` — `@Observable` per-session record: `origin` (local / remote / teleportedFrom), `resumeId`, `title`, `project`, `status` (.spawning/.live/.crashed), `lastActiveAt`, `statusBar`, `connection`, `isThinking`, `isAsking`, `isWaiting`. **Canonical owner** of the strong `ShimProcess` and `WKWebView` references
- `SidebarRow.swift` — Row enum (`.open` / `.closedLocal` / `.closedCloud`) + `sorted(_:)` (open block insertion-order, closed block date desc) + `deduped(_:teleportedFromMap:)` (drops cloud rows already teleported)
- `SidebarFilter.swift` — Codable filter (`status`, `origin`, `project`, `lastActivity`) with `apply(to:)` + `projects(in:)`
- `SessionStorePersistence.swift` — JSON-encoded filter / lastActiveResumeId / hiddenIds in UserDefaults
- `RemoteSessionsAPI.swift` — Direct `/v1/sessions` REST call using OAuth from Keychain, classifies entries Web / Local / Bridged, parses GitHub repo URLs (https + ssh + scp form)
- `RemoteSessionsBridge.swift` — Short-lived shim subprocess for `teleport_session` / `checkout_branch` / `update_skipped_branch` IPC; SIGTERM → SIGKILL escalation, idempotent shutdown
- `AppState.swift` — Per-launcher observable state (PermissionMode enum, working directory, model/effort, screen transitions). Used by `LauncherView` embedded in `DetailLauncher`; the global app no longer owns one
- `ShimProcess.swift` — Node.js subprocess manager, WKScriptMessageHandler, NDJSON bridge, auth/permission patching, process tree cleanup, `boundSession` weak ref, permission-request tracking, `AskUserQuestion` detection
- `NodeDiscovery.swift` — Finds Node.js >= 18 (Homebrew, mise, nvm, login shell), result cached
- `LauncherView.swift` — Welcome screen: directory picker, recent dirs, session history, drag-and-drop, SSH remote toggle, model/effort/permission selectors
- `WebViewContainer.swift` — `NSViewRepresentable` wrapping an NSView host; swaps the WKWebView subview in-place via `updateNSView` when `boundSession.id` changes (~10–30 ms switching, no re-mount). Reuses `boundSession.webView` when present. Registers four WKScriptMessageHandlers: `vscodeHost` (ShimProcess — NDJSON bridge), `consoleLog` (ConsoleLogHandler), `canopyLink` (LinkClickHandler), `canopyInputWidth` (InputWidthMessageHandler). **Any new handler MUST be added to `dismantleNSView` AND the cached-webView reattach block AND `doReconnect` if it needs per-shim rewire** — else session-swap-then-swap-back leaves stale handlers wired to released observables (silent breakage today, `NSInvalidArgumentException` on duplicate-name re-add if the pattern ever tightens)
- `ClaudeSessionHistory.swift` — Session JSONL parser, chain walking, cwd extraction, `loadTeleportedFromMap` reads tail 64 KB only
- `RecentDirectories.swift` — MRU directory list in UserDefaults
- `VSCodeStub.swift` — acquireVsCodeApi() JS stub, Monaco theme patch, IME fix, loads theme CSS
- `ImagePreviewScript.swift` — Injected JS: inline thumbnails + click-to-zoom lightbox for image Read tool results. The CC extension's Read renderer is `body(){return null}` (VSCode shows only the filename; iOS renders natively), so this watches io_message / get_session response streams, pairs Read tool_use ids with base64 image tool_results, and decorates matching "Read <file>" summary rows via MutationObserver (per-file sequence numbers assigned at tool_use time keep row⇔image pairing stable across failed reads / evictions / replays). No dependency on minified identifiers or hashed CSS class names — survives extension minification churn
- `InputWidthProbe.swift` — Injected JS + `InputWidthMessageHandler` bridge that measures the CC extension's chat-input column width and forwards it to `StatusBarData.chatInputWidth` so `SubagentListView` can align with the input area. JS locates the input via `textarea, [contenteditable="true"], [role="textbox"]` (contenteditable div in current builds) filtered to the bottom half of the viewport, walks up to the nearest `border-radius > 0` rounded card (current CC DOM: `FIELDSET.inputContainer_cKsPxg`, ~680pt at 1059pt vw), and reports via `ResizeObserver`(borderBoxSize). Fallbacks (no rounded card, no plausible ancestor, target vanished) each warn to the shared console-log handler so a silent selector-drift regression is discoverable in the unified log
- `CCExtension.swift` — Extension/CLI path discovery
- `StatusBarData.swift` — Observable model for native status bar (context usage, model, CLI version, rate limits, remote host, subagent rows, live `chatInputWidth` from `InputWidthProbe`). `chatInputWidth`'s `didSet` clamps non-positive assignments back to nil so a future direct writer can't collapse the SubagentListView to zero width; `resetAll()` also clears it
- `StatusBarView.swift` — Native SwiftUI status bar: context usage bar, model/version, rate limit indicators, remote host
- `SubagentTracker.swift` — `SubagentInfo` + pure `SubagentTracker`: builds CLI-style subagent task rows from the io_message stream (Agent tool_use launch → parent_tool_use_id usage for tokens → tool_result/result finish → post-result message_start clears). Probe-tested
- `SubagentListView.swift` — Native CLI-style subagent activity list between webview and status bar: spinner/checkmark, agent type, description, live elapsed time, token count; ScrollView cap beyond 8 rows. Width tracks `StatusBarData.chatInputWidth` (from InputWidthProbe) with a 640pt fallback that intentionally under-shoots the empirical ~680pt so the first live measurement always expands (never contracts) the row. Tones match `StatusBarView`: `.tertiary` for agent-type + trailing metrics, `.secondary` for the primary label — never `.primary`, or the row reads as a separate strip from the status bar
- `ContentViewer.swift` — Monaco editor overlay for viewing file contents
- `RemoteDirectoryBrowser.swift` — SSH-backed remote file browser (sheet), lists remote dirs via `ssh host cd path && pwd && ls -1pA`
- `SSHHostStore.swift` — MRU list of SSH hosts in UserDefaults
- `CanopySettings.swift` — Persistent JSON settings (`allowDangerouslySkipPermissions`, `useCtrlEnterToSend`, `respectGitIgnore`, `defaultPermissionMode`). The bypass-permissions toggle clamps `defaultPermissionMode` away from `.bypassPermissions` (didSet + load). `clearStaleSSHWrapper()` migration scrubs pre-env-var wrapper paths from settings.json
- `ConnectionState.swift` — Observable connection status (connected, reconnecting, failed) for SSH overlay
- `ConnectionOverlayView.swift` — SwiftUI overlay showing SSH disconnect/reconnect state
- `KeychainAuth.swift` — Reads CC OAuth blob from macOS Keychain (`Claude Code-credentials`); single source of truth via `readKeychainBlob`, exposes authStatus / accessToken+orgUUID / orgUUID-only readers
- `ExtensionUpdater.swift` — Self-update path for the bundled CC extension; checks for newer versions on launch
- `ModelNameFormatter.swift` — Formats CLI model identifiers into the short labels surfaced in the status bar
- `SessionTitleStore.swift` — Persists per-session AI-generated titles in UserDefaults so closed rows keep their label
- `SettingsView.swift` — Preferences window content: bypass-permissions opt-in toggle, "Default for Recents" permission Picker, "Use Ctrl+Enter to Send" toggle, "Respect .gitignore in File Search" toggle, saved SSH hosts list with delete buttons
- `SharedRateLimitData.swift` — Cross-session rate-limit observable; the shim broadcasts limit events here and the status bar reads from it
- `_SidebarLogicProbe.swift` — DEBUG-only probe (`CANOPY_RUN_LOGIC_PROBE=1`): unit tests for sort / dedup / filter / scheduled-task / automated-session (`claude -p` / SDK `entrypoint: "sdk-*"` — sdk-cli, sdk-py) detection / background-task launch detection (`run_in_background` tool_use blocks) / JSONL `<task-notification>` completion-marker matching (the wake-up reconcile contract) / title-generation helpers (prompt extraction, pinned trimming) / git worktree helpers (sanitize, isGitRepo, projectDisplayName)
- `_ProbeWebViewRetention.swift` — DEBUG-only probe kept as historical reference: validates the early ZStack/opacity-based retention pattern that was superseded by the in-place subview swap shipped in `WebViewContainer`
- `theme-light.css` — 456 CSS variables exported from VSCode Default Light+ theme

### Custom Styles (Resources/)
- `canopy-overrides.css` — Custom CSS overrides: typography, code blocks, --app-* bridge vars, WKWebView fixes, timeline fix
- `prism-canopy.css` — Prism.js syntax highlighting theme matching Claude Desktop Code colors

### SSH Remote (Resources/)
- `ssh-claude-wrapper.sh` — Process wrapper: strips local paths, runs `claude` on remote via SSH

### VSCode Shim (Resources/vscode-shim/)
- `index.js` — Entry point: console redirect, Module hook, arg parsing, activate, stdin routing
- `protocol.js` — NDJSON stdin/stdout read/write
- `types.js` — Uri, EventEmitter, Disposable, Range, Position, Selection, enums
- `context.js` — ExtensionContext with JSON-backed globalState, file-backed secrets, asAbsolutePath, CC auth gate enabled
- `commands.js` — registerCommand, executeCommand, setContext
- `workspace.js` — getConfiguration (3-layer), workspaceFolders, findFiles, openTextDocument
- `window.js` — Webview bridge (postMessage ↔ stdin/stdout), stubs, showTextDocument
- `notifications.js` — showInformationMessage/Error/Warning with 60s timeout
- `env.js` — appName, machineId (persisted), clipboard, openExternal
- `stubs.js` — Proxy-based unknown API detection, module assembly

### Tests (test/)
- `shim-unit.test.js` — 97 unit tests for all shim modules
- `shim-integration.test.js` — 7 integration tests with real extension.js via stdio
- `helpers.js` — Test harness (spawnShim, waitFor, sendRequest)

## CC Extension Webview Details
- Location: `~/.vscode/extensions/anthropic.claude-code-*/webview/`
- Framework: React 18 + Preact Signals
- Must use `loadFileURL` (NOT `loadHTMLString`) for local file access
- Writes `_canopy.html` to `~/Library/Application Support/Canopy/` as entry point

## Protocol Quick Reference
```
Webview → Host:  raw postMessage via acquireVsCodeApi()
Host → Webview:  { type: "from-extension", message: <inner> }

Startup: init → get_claude_state → get_asset_uris → list_sessions → launch_claude (auto)
Chat:    io_message(user) → CLI stdin
         CLI stdout → stream_event/assistant/user/result → io_message → webview
```

## CLI Bridge Details
- CLI flags: `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`
- `--include-partial-messages` is KEY: makes CLI output real Anthropic SSE events as `stream_event` NDJSON lines
- CLI event types: `system`, `stream_event`, `assistant`, `user`, `result`, `rate_limit_event`
- `stream_event` contains real Anthropic SSE: message_start, content_block_start, content_block_delta (text_delta, thinking_delta), content_block_stop, message_delta, message_stop
- All events are forwarded directly to webview as io_message — NO conversion needed
- Webview io_message format: `{ type: "user", message: { role: "user", content: [{type:"text",text:"..."}] } }`
- Convert content array to plain string before sending to CLI stdin

## Key Learnings (Shim-specific)
- Extension sends two message formats: unsolicited wrapped in `{type:"from-extension"}`, responses NOT wrapped — ShimProcess must detect and wrap responses
- **Auth architecture**: `tengu_vscode_cc_auth` must be forced to `true` — extension uses Secrets API (file-backed in shim) for auth management. This enables `/login`, "Switch Account", and proper OAuth flow. Canopy injects Keychain auth into `init_response` only (not `update_state`) as a bootstrap for first launch. The extension's Node.js HTTP callback server on `127.0.0.1:0` handles OAuth redirects; `open_url` opens the OAuth URL in the default browser (supports 1Password etc.). Do NOT inject authStatus into `update_state` — it prevents logout/re-login.
- Webview reads `data-initial-auth-status` HTML attribute for instant auth — inject cached authStatus here
- `update_state` handler: `this.authStatus.value = state.authStatus ?? null` — any update_state without authStatus resets auth to null
- `isAuthenticated` checks: (1) `forceLogin` not true, (2) `authStatus !== null`, (3) fallback: `claudeConfig.account`
- Permission mode UI: controlled by synthetic `system/status` io_message in launch_claude intercept, NOT by `initialPermissionMode`
- `init_response` lacks `authStatus` — injected from auth cache. `isOnboardingDismissed` must be patched to `true`
- ShimProcess patches `init_response` (authStatus + permissionMode + experimentGates + isOnboardingDismissed) and `update_state` (permissionMode + experimentGates + isOnboardingDismissed only — no authStatus)
- **SSH remote patches** (in `vscode-shim/index.js`, gated on `CANOPY_SSH_HOST` env var):
  - `fs.realpathSync` (+ `.native`) returns the input path unresolved on `ENOENT` — the CC extension's unguarded `realpathSync(workspaceFolder)` during webview view setup would otherwise crash the shim when the workspace lives only on the remote
  - `child_process.spawn` rewrites a missing `cwd` to `$HOME` **only** for spawns whose command matches `CANOPY_SSH_WRAPPER_PATH`. Other spawns (git, ripgrep, MCP) pass through untouched so they fail cleanly instead of silently running in `$HOME` and returning wrong results
- **Per-shim config overrides** (in `vscode-shim/workspace.js`): `getConfiguration` merges `envOverrides` as the highest-priority layer ahead of the shared Canopy settings file. SSH wrapper flows `ShimProcess.swift → CANOPY_SSH_WRAPPER_PATH → envOverrides["claudeCode.claudeProcessWrapper"]`. `get`/`has`/`inspect` all see the override. Avoids leaking per-session config through the shared file and surviving `/resume` re-spawns

## Key Learnings (General)
- `--bare` flag skips keychain/OAuth auth — do NOT use
- `--include-partial-messages` makes CLI output `stream_event` (real SSE) not just `assistant` (batch)
- **CSS loading order**: theme-light.css → extension index.css → canopy-overrides.css → prism-canopy.css. Later layers override earlier ones
- **Bundled CSS is inlined**: Bundle.main is outside WKWebView's `allowingReadAccessTo` scope, so canopy-overrides.css and prism-canopy.css are read into strings and embedded as `<style>` blocks
- VSCode injects default CSS (`@layer vscode-default`) into webviews — Canopy replicates this in canopy-overrides.css
- VSCode sets `<body class="vscode-light">` which CC extension CSS uses for theme-specific overrides
- CC extension defines `--app-*` CSS vars mapped to `--vscode-*` vars in its own CSS
- `--app-code-background` is NOT defined in CC extension CSS — must be provided by host
- Timeline lines use `position:absolute` `:after` pseudo-elements; need `bottom: -15px` CSS fix because each timelineMessage is also a .message (position:relative)
- Theme CSS: export from VSCode via "Developer: Generate Color Theme From Current Settings", convert with script
- Monaco diff editor: CC extension hardcodes `theme:"vs-dark"` — VSCodeStub.swift redefines vs-dark as a light theme
- Japanese IME: WebKit Bug 165004 — `compositionend` fires before `keydown`, patched via keyCode 229 check
- Logging: use `os_log` (Logger) not `print()` — print doesn't work when launched via `open`
- **macOS 26 Tahoe `NSRegularExpression` + bg queue = crash**: `NSRegularExpression.enumerateMatches` invoked on a background `DispatchQueue` (custom or `.global(qos:)`) trips a spurious main-thread precondition inside Foundation and hard-crashes with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue [com.apple.main-thread]` — even when the closure never reads or writes anything main-actor-isolated. Reproduced ~20% of session opens; the crashing thread is the bg worker itself. `numberOfMatches` on the same regex is safe; only `enumerateMatches` with a closure trips it. Workaround: write a pure-Swift byte scanner instead. `extractToolUseIds` in `ShimProcess.swift` is the reference example. If you need another regex on a bg thread, do NOT use `NSRegularExpression` — write the scanner
- **Debugging injected JS from Swift**: when `console.log` from the webview isn't reaching the ConsoleLogHandler for whatever reason (script order, teardown race, extension overriding console), add a `type: "debug"` branch to your own `WKScriptMessageHandler` and post from JS via `handler.postMessage({type:'debug', msg:'...'})`. Read via `log show --predicate 'process == "Canopy" AND subsystem == "sh.saqoo.Canopy" AND category == "<YourHandler>"' --last 2m --style compact --info --debug`. Once the shape is confirmed, strip the debug branch
- **CC extension chat-input DOM** (as of extension 2.1.210): the input is a **contenteditable `<div>`**, not a `<textarea>` — the working DOM path from the input up is `DIV.messageInput_cKsPxg` (~678pt) → `DIV.messageInputContainer_cKsPxg` (678) → `FIELDSET.inputContainer_cKsPxg` (~680, visible rounded card — this is what UI overlays should align with) → `FORM` → `DIV.inputWrapper_cKsPxg` (680) → outer chat column `DIV.inputContainer_07S1Yg` (~1027pt at 1059pt viewport). Class-name suffixes churn between extension versions; select by shape (border-radius / rect-width) not by class

## Theme Management
To update theme CSS:
1. Open VSCode with desired theme active
2. Cmd+Shift+P → "Developer: Generate Color Theme From Current Settings"
3. Save as JSON, clean JSONC comments, convert to CSS with the node script
4. Replace `Sources/Canopy/theme-light.css`

## Session Management
- Sidebar shell shortcuts: Cmd+N selects the Launcher row (new session), Cmd+O opens folder picker, Cmd+W closes the active session (falls back to the focused non-main window — Settings / Sparkle alert — if the main Canopy window isn't key, and to closing the main window when no session is active), Cmd+Shift+W closes the focused window via `performClose(nil)` so the active-session prompt fires, Cmd+0 brings the main window forward (or `openWindow(id:"main")` if it was destroyed), Cmd+1..9 switches to the N-th open session (closed rows are skipped)
- Sessions toggle between **open** (live shim, hot, instant switch) and **closed** (history only — click to reopen). Active row stays at its insertion-order position; new opens append to the bottom
- Window frame is persisted under `canopy.mainWindowFrame` UserDefaults (didResize + didMove → save; first `configureCanopyWindow` → restore, clamped to current screen `visibleFrame`). AppKit's autosave was unusable: SwiftUI assigns each fresh `WindowGroup(id: "main")` instance a different `main-AppWindow-N` autosave key, so a "Stop Sessions and Close" + Cmd+0 round-trip kept resetting to defaultSize
- Default permission mode for recents lives in `canopy.defaultPermissionMode` (settings.json key, exposed in Settings → "Permission Mode → Default for Recents"). `SessionStore.openLocal/openCloud` fall through to this when the caller doesn't pass an override; the Launcher view tracks its own per-session selection independently
- Active session uses an in-place WKWebView subview swap (~10–30 ms), so switching keeps DOM state. WebView is cached on `OpenSession.webView`; the shim is owned via a strong ref on `OpenSession.shim`
- `list_sessions_request` returns real sessions from `~/.claude/projects/`
- Session resume: `--resume SESSION_ID` flag passed to CLI
- History replay: reads JSONL, walks parentUuid chain from leaf, sends via sync `dispatchEvent` (not async `postMessage`) for instant single-render display
- Path encoding: `encodePath` replaces `/` and `.` with `-` (matching CLI behavior)
- Background scheduled-task JSONLs (Claude Code `queue-operation` enqueue with `<scheduled-task` in `content`) are excluded from sidebar recents and launcher session lists
- `loadAllSessions` reads `cwd` from JSONL metadata (avoids lossy path decoding)
- PermissionMode: type-safe enum (default, acceptEdits, auto, plan, dontAsk, bypassPermissions)

## Release Scripts
```bash
./scripts/release.sh 1.5.2      # Full release: build, sign, notarize, DMG, GitHub release, appcast
./scripts/update_appcast.sh 1.5.2  # Update appcast only (after editing GitHub Release notes)
```
- `release.sh` — Bumps version, builds Release, creates signed/notarized DMG, creates GitHub Release, updates appcast
- `update_appcast.sh` — Fetches release notes from GitHub, generates appcast with Sparkle's `generate_appcast`, pushes to gh-pages
- Appcast URL: `https://saqoosha.github.io/Canopy/appcast.xml`
- EdDSA signing key stored in macOS Keychain (shared with Sessylph)

## SSH Remote
- Toggle "SSH Remote" in launcher, enter hostname (e.g. `mbp`, `user@server`)
- Browse... opens SSH-backed remote directory browser
- Uses CC extension's `claudeProcessWrapper` setting with bundled `ssh-claude-wrapper.sh`
- Wrapper strips local node/claude paths, runs `claude` command on remote with CLI flags
- `CANOPY_SSH_HOST` env var passes target host to wrapper script
- Wrapper path flows via `CANOPY_SSH_WRAPPER_PATH` env var → vscode-shim `workspace.js` exposes it as a per-shim `claudeCode.claudeProcessWrapper` override (layer 0, highest priority in `get`/`has`/`inspect`). Avoids writing to the shared settings file, which otherwise leaks across concurrent open sessions and was eagerly cleared mid-session, breaking `/resume`
- `CanopySettings.clearStaleSSHWrapper()` runs once on local session launch to scrub pre-env-var values left by older Canopy builds; only removes entries whose basename is `ssh-claude-wrapper.sh` so user-configured custom wrappers stay intact
- Remote machine needs: Claude CLI installed + `claude login` done once interactively
- Remote sessions surface the host as `host:dir` in the navigation subtitle (project line); the status bar shows a network icon + hostname in orange
- Saved hosts persisted via `SSHHostStore` (UserDefaults), manageable in Preferences

### Connection Management (Phase 3)
- SSH keepalive: `ServerAliveInterval=15`, `ServerAliveCountMax=3` — detects dead connections within 45s
- Auto-reconnect framework: 3 attempts with exponential backoff (3s, 6s, 12s), uses `--resume SESSION_ID`
- UI overlay: semi-transparent overlay on webview showing disconnect/reconnect state
- Only activates for remote sessions with an established session ID
- `ConnectionState` (@Observable) owns status + onRetry closure; `ConnectionOverlayView` renders it
- `ShimProcessDelegate` protocol: `shimProcessDidDisconnect(_:sessionId:)` — Coordinator implements
- `retryReconnect()` calls `cancelReconnect()` first to prevent concurrent reconnect attempts

#### Known Limitation (Phase 3.1)
SSH death kills the CLI subprocess but Node.js shim stays alive → `terminationHandler` does NOT fire → overlay is NOT triggered automatically. The CC extension detects CLI exit and shows error banner (exit code 255). The framework is built; Phase 3.1 will add detection via shim stderr or extension message.

### Remaining Limitations
- `@`-mention file listing doesn't work (workspace.fs is local)
- `open_file` / ContentViewer can't read remote files

## Next Steps
1. SSH remote Phase 3.1 — detect CLI exit via shim to trigger reconnect overlay
2. SSH remote Phase 2 — remote file operations via SSH for @-mention support

## Design & Plan Docs
- `docs/superpowers/specs/2026-03-29-vscode-shim-design.md` — Full design spec (500 lines)
- `docs/superpowers/plans/2026-03-29-vscode-shim.md` — Implementation plan (15 tasks)
- `docs/superpowers/specs/2026-03-31-ssh-remote.md` — SSH remote design spec + validation results
- `docs/superpowers/plans/2026-03-31-ssh-remote.md` — SSH remote implementation plan (8 tasks)
- `docs/superpowers/specs/2026-03-31-ssh-connection-management.md` — Phase 3 design spec
- `docs/superpowers/plans/2026-03-31-ssh-connection-management.md` — Phase 3 implementation plan
- `docs/superpowers/specs/2026-04-29-single-window-sidebar.md` — Single-window sidebar shell design spec
- `docs/superpowers/plans/2026-04-29-single-window-sidebar.md` — Single-window sidebar implementation plan

## Running Tests
```bash
# Unit tests (no external deps, fast)
node --test test/shim-unit.test.js

# Integration tests (needs CC extension installed, slow ~60s)
node --test --test-timeout 120000 test/shim-integration.test.js
```
