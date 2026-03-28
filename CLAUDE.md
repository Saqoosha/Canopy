# Hangar — Claude Code Extension Webview Host

## What Is This

macOS native app that hosts the Claude Code VSCode extension's webview (React UI) in a WKWebView. No VSCode required. The CC extension's bundled JS/CSS renders directly in a native macOS window with real-time streaming.

## Project Status: Working Chat with Session Management (2026-03-28)

Full chat with Claude works. Launcher screen with directory picker, session history with instant replay, real auth, CLI process, real SSE streaming, tool use display, light theme matching VSCode.

## Tech Stack
- macOS 15.0+, Swift 6
- WKWebView hosting CC extension's React webview
- xcodegen for project generation from `project.yml`
- Bundle ID: `sh.saqoo.Hangar`

## Build Commands
```bash
xcodegen generate
xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Hangar.app
```

## Architecture

```
WKWebView
  │  loads ~/.vscode/extensions/anthropic.claude-code-*/webview/index.{js,css}
  │
  ├─ acquireVsCodeApi() stub → bridges postMessage to Swift via WKScriptMessageHandler
  ├─ VSCode Light+ theme (456 vars from real VSCode export) + VSCode default webview CSS
  ├─ <body class="vscode-light">
  ├─ window.IS_FULL_EDITOR = true
  │
  ▼
WebViewMessageHandler (Swift)
  │  handles protocol: init, get_claude_state, get_asset_uris, launch_claude, io_message
  │  real auth via `claude auth status`
  │
  ▼
ClaudeProcess (Swift)
  │  spawns `claude -p --input-format stream-json --output-format stream-json
  │         --verbose --include-partial-messages`
  │  CLI outputs real SSE `stream_event` lines → forwarded directly to webview
  │
  ▼
Claude CLI (user's installed claude binary)
```

## Key Source Files
- `HangarApp.swift` — SwiftUI app entry, launcher ↔ session switching, window title, menu commands
- `AppState.swift` — Observable app state, PermissionMode enum, screen transitions
- `LauncherView.swift` — Welcome screen: directory picker, recent dirs, session history, drag-and-drop
- `WebViewContainer.swift` — WKWebView setup, CC webview loading, VSCode default CSS injection
- `WebViewMessageHandler.swift` — Protocol handler, auth, CLI launch, IO bridge, session history replay
- `ClaudeProcess.swift` — Claude CLI process lifecycle, NDJSON parsing, --resume support
- `ClaudeSessionHistory.swift` — Session JSONL parser, chain walking, cwd extraction
- `RecentDirectories.swift` — MRU directory list in UserDefaults
- `VSCodeStub.swift` — acquireVsCodeApi() JS stub, loads theme CSS from bundled resource
- `CCExtension.swift` — Extension/CLI path discovery
- `theme-light.css` — 456 CSS variables exported from VSCode Default Light+ theme

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
1. Dark mode — support system appearance switching (theme-dark.css)
2. Window chrome — app icon, titlebar, tabs
3. Direct API streaming — bypass CLI for true character-level streaming (CLI already provides this via stream_event!)
