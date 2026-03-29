# Hangar — Claude Code Extension Webview Host

## What Is This

macOS native app that hosts the Claude Code VSCode extension's webview (React UI) in a WKWebView. No VSCode required. The CC extension's bundled JS/CSS renders directly in a native macOS window with real-time streaming.

## Project Status: VSCode Shim in Progress (2026-03-29)

Full chat with Claude works. Launcher screen with directory picker, session history with instant replay, real auth, CLI process, real SSE streaming, tool use display, light theme matching VSCode.

**Active work: vscode-shim** — replacing the 1409-line Swift protocol handler with a Node.js subprocess that runs `extension.js` unmodified. JS modules complete (10 files, 104 tests passing). Swift integration (Tasks 11-15) pending.

## Tech Stack
- macOS 15.0+, Swift 6
- WKWebView hosting CC extension's React webview
- Node.js >= 18 (for vscode-shim, runs extension.js natively)
- xcodegen for project generation from `project.yml`
- Bundle ID: `sh.saqoo.Hangar`

## Build Commands
```bash
xcodegen generate
xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Hangar.app
```

## Architecture

### Current (Swift protocol handler)
```
WKWebView ─── postMessage ──→ WebViewMessageHandler.swift (1409 lines)
                                  └─→ ClaudeProcess.swift ─→ Claude CLI
```

### Target (vscode-shim — in progress)
```
WKWebView ─── postMessage ──→ ShimProcess.swift (~150 lines)
                                  │ stdin/stdout NDJSON
                                  ▼
                              Node.js subprocess
                                  ├─ vscode-shim/ (10 JS modules, ~800 lines)
                                  │    └─ intercepts require("vscode")
                                  └─ extension.js (CC extension, unmodified)
                                       └─ spawns Claude CLI via child_process
```

The vscode-shim approach runs extension.js as-is — no protocol reimplementation needed. Extension updates require zero Hangar code changes. See `docs/superpowers/specs/2026-03-29-vscode-shim-design.md` for full spec.

## Key Source Files

### Swift (Sources/Hangar/)
- `HangarApp.swift` — SwiftUI app entry, launcher ↔ session switching, window title, menu commands
- `AppState.swift` — Observable app state, PermissionMode enum, screen transitions
- `LauncherView.swift` — Welcome screen: directory picker, recent dirs, session history, drag-and-drop
- `WebViewContainer.swift` — WKWebView setup, CC webview loading, VSCode default CSS injection
- `WebViewMessageHandler.swift` — **LEGACY** protocol handler (to be replaced by ShimProcess)
- `ClaudeProcess.swift` — **LEGACY** CLI process lifecycle (to be replaced by vscode-shim)
- `ClaudeSessionHistory.swift` — Session JSONL parser, chain walking, cwd extraction
- `RecentDirectories.swift` — MRU directory list in UserDefaults
- `VSCodeStub.swift` — acquireVsCodeApi() JS stub, loads theme CSS from bundled resource
- `CCExtension.swift` — Extension/CLI path discovery
- `ContentViewer.swift` — Monaco editor overlay for viewing file contents
- `theme-light.css` — 456 CSS variables exported from VSCode Default Light+ theme

### VSCode Shim (Resources/vscode-shim/)
- `index.js` — Entry point: console redirect, Module hook, arg parsing, activate, stdin routing
- `protocol.js` — NDJSON stdin/stdout read/write
- `types.js` — Uri, EventEmitter, Disposable, Range, Position, Selection, enums
- `context.js` — ExtensionContext with JSON-backed globalState
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
- Writes `_hangar.html` to `~/Library/Application Support/Hangar/` as entry point

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

## Key Learnings
- `--bare` flag skips keychain/OAuth auth — do NOT use
- `--include-partial-messages` makes CLI output `stream_event` (real SSE) not just `assistant` (batch)
- VSCode injects default CSS (`@layer vscode-default`) into webviews — includes `code { background-color }`, link colors, scrollbar styles
- VSCode sets `<body class="vscode-light">` which CC extension CSS uses for theme-specific overrides
- CC extension defines `--app-*` CSS vars mapped to `--vscode-*` vars in its own CSS
- `--app-code-background` is NOT defined in CC extension CSS — must be provided by host
- Timeline lines use `position:absolute` `:after` pseudo-elements; need `bottom: -15px` CSS fix because each timelineMessage is also a .message (position:relative)
- Theme CSS: export from VSCode via "Developer: Generate Color Theme From Current Settings", convert with script
- Logging: use `os_log` (Logger) not `print()` — print doesn't work when launched via `open`

## Theme Management
To update theme CSS:
1. Open VSCode with desired theme active
2. Cmd+Shift+P → "Developer: Generate Color Theme From Current Settings"
3. Save as JSON, clean JSONC comments, convert to CSS with the node script
4. Replace `Sources/Hangar/theme-light.css`

## Session Management
- Launcher screen: Cmd+N returns to launcher, Cmd+O opens folder picker
- `list_sessions_request` returns real sessions from `~/.claude/projects/`
- Session resume: `--resume SESSION_ID` flag passed to CLI
- History replay: reads JSONL, walks parentUuid chain from leaf, sends via sync `dispatchEvent` (not async `postMessage`) for instant single-render display
- Path encoding: `encodePath` replaces `/` and `.` with `-` (matching CLI behavior)
- `loadAllSessions` reads `cwd` from JSONL metadata (avoids lossy path decoding)
- PermissionMode: type-safe enum (default, acceptEdits, plan, bypassPermissions)

## Next Steps
1. **Complete vscode-shim Swift integration** — Tasks 11-15: ShimProcess.swift, NodeDiscovery.swift, Xcode bundling, feature flag, smoke test, cleanup
2. Dark mode — support system appearance switching (theme-dark.css)
3. SSH remote — run vscode-shim on remote machines via `ssh -T` (design spec Phase 5)
4. Window chrome — app icon, titlebar, tabs

## Design & Plan Docs
- `docs/superpowers/specs/2026-03-29-vscode-shim-design.md` — Full design spec (500 lines)
- `docs/superpowers/plans/2026-03-29-vscode-shim.md` — Implementation plan (15 tasks)

## Running Tests
```bash
# Unit tests (no external deps, fast)
node --test test/shim-unit.test.js

# Integration tests (needs CC extension installed, slow ~60s)
node --test --test-timeout 120000 test/shim-integration.test.js
```
