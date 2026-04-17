# Canopy — Claude Code Extension Webview Host

## What Is This

macOS native app that hosts the Claude Code VSCode extension's webview (React UI) in a WKWebView. No VSCode required. The CC extension's bundled JS/CSS renders directly in a native macOS window with real-time streaming.

## Project Status: Fully Working (2026-04-04)

Full chat with Claude works via vscode-shim. Launcher screen with directory picker, session history with instant replay, real auth, CLI process, real SSE streaming, tool use display, light theme matching VSCode, permission mode sync, slash commands, tabbed windows, Sparkle auto-update, **SSH remote**. Launcher includes model/effort/permission selectors.

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
- `CanopyApp.swift` — SwiftUI app entry, tabs, menu commands, Sparkle updater
- `AppState.swift` — Observable app state, PermissionMode enum, screen transitions, StatusBarData reset on session launch
- `ShimProcess.swift` — Node.js subprocess manager, WKScriptMessageHandler, NDJSON bridge, auth/permission patching, process tree cleanup
- `NodeDiscovery.swift` — Finds Node.js >= 18 (Homebrew, mise, nvm, login shell), result cached
- `LauncherView.swift` — Welcome screen: directory picker, recent dirs, session history, drag-and-drop, SSH remote toggle, model/effort/permission selectors
- `WebViewContainer.swift` — WKWebView setup, CC webview loading, VSCode default CSS injection
- `ClaudeSessionHistory.swift` — Session JSONL parser, chain walking, cwd extraction
- `RecentDirectories.swift` — MRU directory list in UserDefaults
- `VSCodeStub.swift` — acquireVsCodeApi() JS stub, Monaco theme patch, IME fix, loads theme CSS
- `CCExtension.swift` — Extension/CLI path discovery
- `StatusBarData.swift` — Observable model for native status bar (context usage, model, CLI version, rate limits, remote host)
- `StatusBarView.swift` — Native SwiftUI status bar: context usage bar, model/version, rate limit indicators, remote host
- `ContentViewer.swift` — Monaco editor overlay for viewing file contents
- `RemoteDirectoryBrowser.swift` — SSH-backed remote file browser (sheet), lists remote dirs via `ssh host cd path && pwd && ls -1pA`
- `SSHHostStore.swift` — MRU list of SSH hosts in UserDefaults
- `CanopySettings.swift` — Persistent settings (permission mode, wrapper path, etc.), JSON-backed
- `ConnectionState.swift` — Observable connection status (connected, reconnecting, failed) for SSH overlay
- `ConnectionOverlayView.swift` — SwiftUI overlay showing SSH disconnect/reconnect state
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

## Theme Management
To update theme CSS:
1. Open VSCode with desired theme active
2. Cmd+Shift+P → "Developer: Generate Color Theme From Current Settings"
3. Save as JSON, clean JSONC comments, convert to CSS with the node script
4. Replace `Sources/Canopy/theme-light.css`

## Session Management
- Launcher screen: Cmd+N returns to launcher, Cmd+O opens folder picker
- `list_sessions_request` returns real sessions from `~/.claude/projects/`
- Session resume: `--resume SESSION_ID` flag passed to CLI
- History replay: reads JSONL, walks parentUuid chain from leaf, sends via sync `dispatchEvent` (not async `postMessage`) for instant single-render display
- Path encoding: `encodePath` replaces `/` and `.` with `-` (matching CLI behavior)
- `loadAllSessions` reads `cwd` from JSONL metadata (avoids lossy path decoding)
- PermissionMode: type-safe enum (default, acceptEdits, auto, plan, bypassPermissions)

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
- Wrapper path flows via `CANOPY_SSH_WRAPPER_PATH` env var → vscode-shim `workspace.js` exposes it as a per-shim `claudeCode.claudeProcessWrapper` override (layer 0, highest priority in `get`/`has`/`inspect`). Avoids writing to the shared settings file, which otherwise leaks across concurrent windows and was eagerly cleared mid-session, breaking `/resume`
- `CanopySettings.clearStaleSSHWrapper()` runs once on local session launch to scrub pre-env-var values left by older Canopy builds; only removes entries whose basename is `ssh-claude-wrapper.sh` so user-configured custom wrappers stay intact
- Remote machine needs: Claude CLI installed + `claude login` done once interactively
- Window title shows `[hostname]` prefix (orange), status bar shows network icon + hostname
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

## Running Tests
```bash
# Unit tests (no external deps, fast)
node --test test/shim-unit.test.js

# Integration tests (needs CC extension installed, slow ~60s)
node --test --test-timeout 120000 test/shim-integration.test.js
```
