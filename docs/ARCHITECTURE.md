# Architecture

Detailed technical architecture of Hangar, a macOS app that hosts the Claude Code VSCode extension's webview in a native WKWebView and bridges it to a real Claude CLI process.

## System Overview

```
+------------------------------------------------------------------+
|  HangarApp (SwiftUI)                                             |
|  WindowGroup > WebViewContainer (NSViewRepresentable)            |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |  WKWebView                                                 |  |
|  |                                                            |  |
|  |  Injected at document start:                               |  |
|  |    1. Console capture (log/error/warn -> consoleLog)       |  |
|  |    2. VSCodeStub (acquireVsCodeApi, IS_FULL_EDITOR, etc.)  |  |
|  |                                                            |  |
|  |  Loaded via loadFileURL(_hangar.html):                     |  |
|  |    - theme-light.css (456 --vscode-* CSS variables)        |  |
|  |    - VSCode default webview CSS (@layer vscode-default)    |  |
|  |    - --app-* bridge variables                              |  |
|  |    - Timeline CSS fix                                      |  |
|  |    - CC extension index.css + index.js                     |  |
|  |                                                            |  |
|  |  <body class="vscode-light">                               |  |
|  |    <div id="root"></div>  (React mount point)              |  |
|  +------+-------------------------------------------+---------+  |
|         |                                           |            |
|   WKScriptMessageHandler                  window.postMessage     |
|   "vscodeHost"          "consoleLog"       (from-extension)      |
|         |                    |                      ^            |
|  +------v--------------------v----------------------+----------+  |
|  |  WebViewMessageHandler                                      |  |
|  |                                                             |  |
|  |  Handles:                                                   |  |
|  |    request    -> init, get_claude_state, get_asset_uris,    |  |
|  |                  list_sessions, login, open_url, ...        |  |
|  |    launch_claude -> spawn ClaudeProcess                     |  |
|  |    io_message    -> forward user input to CLI stdin         |  |
|  |    interrupt_claude -> SIGINT to CLI                        |  |
|  |    close_channel   -> terminate CLI process                 |  |
|  |                                                             |  |
|  |  ConsoleLogHandler (separate handler for JS console bridge) |  |
|  +------+-------------------------------------------+----------+  |
|         |                                           ^            |
|     stdin (NDJSON)                           stdout (NDJSON)     |
|         |                                           |            |
|  +------v-------------------------------------------+----------+  |
|  |  ClaudeProcess                                              |  |
|  |                                                             |  |
|  |  Process:  claude -p --input-format stream-json             |  |
|  |              --output-format stream-json --verbose           |  |
|  |              --include-partial-messages                      |  |
|  |              --permission-mode <mode>                        |  |
|  |              --session-id <uuid>                             |  |
|  |                                                             |  |
|  |  NDJSON parser: line buffer -> JSON -> event routing        |  |
|  |  Thread safety: serial DispatchQueue                        |  |
|  +-------------------------------------------------------------+  |
|                                                                  |
|  +-------------------------------------------------------------+  |
|  |  CCExtension (utility enum)                                 |  |
|  |    extensionPath() -> ~/.vscode/extensions/anthropic.cc-*   |  |
|  |    cliBinaryPath() -> ~/.local/bin/claude or fallbacks      |  |
|  +-------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

## Component Descriptions

### HangarApp.swift

SwiftUI `@main` entry point. Creates a single `WindowGroup` containing a `WebViewContainer`. Sets minimum window size (400x600) and default size (500x800). Uses standard titlebar window style.

### CCExtension.swift

Static utility enum for finding Claude Code paths on disk:

- `extensionPath()` -- Scans `~/.vscode/extensions/` for directories matching `anthropic.claude-code-*`, returns the latest version (sorted descending by directory name).
- `cliBinaryPath()` -- Checks `~/.local/bin/claude`, `/usr/local/bin/claude`, and `/opt/homebrew/bin/claude` for an executable Claude CLI binary.

### WebViewContainer.swift

`NSViewRepresentable` that creates and configures the WKWebView. This is where the CC extension webview is assembled and loaded.

**WKWebView configuration:**
- `allowFileAccessFromFileURLs` enabled (required for loading extension JS/CSS from local filesystem)
- `isInspectable = true` (enables Safari Web Inspector)
- Two `WKUserScript` injections at document start:
  1. Console capture script (bridges `console.log/error/warn` to Swift via `consoleLog` message handler)
  2. VSCode API stub (from `VSCodeStub.swift`)
- Two `WKScriptMessageHandler` registrations:
  1. `vscodeHost` -- handled by `WebViewMessageHandler`
  2. `consoleLog` -- handled by `ConsoleLogHandler`

**HTML generation (`loadCCWebview`):**

Writes `_hangar.html` to `~/Library/Application Support/Hangar/` containing:
1. Theme CSS variables (loaded from bundled `theme-light.css`)
2. CC extension's `index.css` (linked via file URL)
3. Custom CSS overrides: font families, `--app-*` bridge variables, timeline fix
4. VSCode default webview CSS (`@layer vscode-default` -- scrollbar, code, link, kbd styles)
5. `<body class="vscode-light">` with `<div id="root">` mount point
6. CC extension's `index.js` (loaded as ES module)

The HTML file is loaded via `loadFileURL` (not `loadHTMLString`) with read access granted to the user's entire home directory. This is required because the webview needs to access both the HTML file in Application Support and the extension assets under `~/.vscode/extensions/`.

**ConsoleLogHandler:**

Receives JS console output bridged from the webview. Routes to `os_log` at appropriate levels (info for log, warning for warn, error for error). Truncates object serialization to 500 characters to avoid log flooding.

**Cleanup:**

`dismantleNSView` removes all script message handlers and user scripts to prevent retain cycles between WKWebView and the handler objects.

### VSCodeStub.swift

Provides the JavaScript and CSS that make the CC extension believe it is running inside VSCode:

**JavaScript stub:**
- Sets `window.IS_SIDEBAR = false`, `window.IS_FULL_EDITOR = true`, `window.IS_SESSION_LIST_ONLY = false`
- Implements `window.acquireVsCodeApi()` returning an object with:
  - `postMessage(msg)` -- forwards to `window.webkit.messageHandlers.vscodeHost.postMessage(msg)`
  - `getState()` -- returns null
  - `setState(state)` -- returns state (no-op)

**Theme CSS:**
- Loaded from the bundled `theme-light.css` resource file at runtime
- Contains 456 `--vscode-*` CSS custom properties exported from VSCode's Default Light+ theme
- Falls back to basic black-on-white if the resource file is missing

### WebViewMessageHandler.swift

Central protocol handler. Implements `WKScriptMessageHandler` to receive messages from the webview and dispatches them by type.

**Message types handled:**

| Type | Description |
|------|-------------|
| `request` | Request/response protocol (dispatched by `request.type`) |
| `launch_claude` | Spawn a new Claude CLI process |
| `io_message` | Forward user messages to CLI stdin |
| `interrupt_claude` | Send SIGINT to active CLI process |
| `close_channel` | Terminate CLI process and clean up |

**Request types:**

| Request | Response | Notes |
|---------|----------|-------|
| `init` | `init_response` | App state: cwd, auth, platform, feature flags |
| `get_claude_state` | `get_claude_state_response` | Model list, account info, PID |
| `get_asset_uris` | `asset_uris_response` | SVG/PNG paths for UI assets (clawd, welcome art) |
| `get_current_selection` | Selection response | Always null (no editor) |
| `list_sessions_request` | `list_sessions_response` | Always empty (no persistence) |
| `request_usage_update` | `usage_update` | Always null |
| `login` | `login_response` | Opens claude.ai/login in browser, re-fetches auth |
| `open_url` | `open_url_response` | Opens URL in default browser via NSWorkspace |
| `open_help` | `open_help_response` | Opens Claude Code docs |
| `set_model` | Ack | No-op (not persisted) |
| `set_thinking_level` | Ack | No-op (not persisted) |
| `set_permission_mode` | Ack | No-op (not persisted) |
| `get_mcp_servers` | Empty list | MCP not implemented |
| `list_plugins` | Empty list | Plugins not implemented |
| `generate_session_title` | Static "Chat" | Title generation not implemented |
| Various dismiss/config | Ack | No-op acknowledgments |

**Authentication:**
- On init, runs `claude auth status` as a subprocess and caches the JSON result
- Auth info (email, subscription type, auth method) is included in `init_response` and `get_claude_state_response`
- Login redirects to `claude.ai/login` and re-fetches auth after 5 seconds

**Channel management:**
- Maintains a dictionary of active `ClaudeProcess` instances keyed by `channelId`
- Cleans up old process before creating a new one for the same channel
- Receives exit notifications from `ClaudeProcess` via `handleCLIProcessExited`

### ClaudeProcess.swift

Manages the lifecycle of a single Claude CLI subprocess for one conversation channel.

**Process configuration:**
```
claude -p
  --output-format stream-json
  --input-format stream-json
  --verbose
  --include-partial-messages
  --permission-mode <mode>
  --session-id <uuid>
```

Key flags:
- `-p` -- Non-interactive / piped mode
- `--include-partial-messages` -- Makes CLI output real Anthropic SSE events as `stream_event` NDJSON lines (without this flag, you only get batched `assistant` events)
- `--session-id` -- Generated UUID for each channel

**Thread safety:**
- All mutable state access (line buffer, process writes) goes through a serial `DispatchQueue`
- Class is marked `@unchecked Sendable` because thread safety is manually managed

**NDJSON parsing:**
- `readabilityHandler` on stdout pipe receives raw data chunks
- Data is appended to a line buffer and split on `\n` (0x0A) bytes
- Each complete line is parsed as JSON
- On process termination, remaining buffer is flushed

**Event routing:**

| CLI Event Type | Action |
|---------------|--------|
| `system` | Log init info (model name) |
| `stream_event` | Forward to webview as `io_message` (done=false) |
| `assistant` | Forward to webview as `io_message` (done=false) |
| `user` | Forward to webview as `io_message` (done=false) -- tool results |
| `result` | Forward to webview as `io_message` (done=true) |
| `rate_limit_event` | Forward to webview as `io_message` (done=false) |

**Event forwarding format:**
```json
{
  "type": "from-extension",
  "message": {
    "type": "io_message",
    "channelId": "<channel-id>",
    "message": { /* raw CLI event */ },
    "done": false
  }
}
```

Events are serialized to JSON and sent to the webview via `window.postMessage()` JavaScript evaluation on the main thread.

**stdin writes:**
- User messages are converted from content block arrays to plain text strings before sending
- Written as NDJSON (one JSON object per line) to the CLI's stdin pipe
- Writes are dispatched to the serial queue and check that the process is still running

## Data Flow

### Startup Sequence

```
1. HangarApp creates WindowGroup
2. WebViewContainer.makeNSView:
   a. Create WKWebViewConfiguration
   b. Inject console capture script (atDocumentStart)
   c. Inject VSCode API stub (atDocumentStart)
   d. Register message handlers (vscodeHost, consoleLog)
   e. Enable file access from file URLs
3. WebViewMessageHandler.init:
   a. Spawn `claude auth status` subprocess
   b. Parse and cache auth JSON
4. loadCCWebview:
   a. Find CC extension path
   b. Generate HTML with theme CSS + extension JS/CSS
   c. Write _hangar.html to ~/Library/Application Support/Hangar/
   d. loadFileURL with read access to home directory
5. Webview boots:
   a. React app mounts in <div id="root">
   b. acquireVsCodeApi() returns stub with postMessage bridge
   c. Extension sends: init -> get_claude_state -> get_asset_uris -> list_sessions
   d. Extension auto-launches claude (launch_claude message)
6. ClaudeProcess spawned:
   a. CLI binary found via CCExtension.cliBinaryPath()
   b. Process started with stream-json flags
   c. stdout/stderr readability handlers attached
```

### Chat Message Flow

```
User types message in webview
  |
  v
CC extension calls vscodeApi.postMessage({
  type: "io_message",
  channelId: "...",
  message: { type: "user", message: { role: "user", content: [{type:"text",text:"Hello"}] } }
})
  |
  v
WKScriptMessageHandler receives in WebViewMessageHandler
  |
  v
handleIOMessage extracts text from content blocks -> "Hello"
  |
  v
ClaudeProcess.sendUserMessage writes to stdin:
  {"type":"user","message":{"role":"user","content":"Hello"}}\n
  |
  v
CLI processes and streams NDJSON to stdout:
  {"type":"stream_event","event":{"type":"content_block_delta",...}}\n
  {"type":"stream_event","event":{"type":"content_block_delta",...}}\n
  ...
  {"type":"result","subtype":"success",...}\n
  |
  v
ClaudeProcess.appendData -> line buffer -> processLine
  |
  v
sendIOMessage wraps each event:
  { type: "from-extension", message: { type: "io_message", channelId, message, done } }
  |
  v
evaluateJavaScript("window.postMessage(..., '*')")
  |
  v
CC extension React UI renders streaming text, thinking, tool use
```

### Tool Use Flow

Tool use events flow through the same pipeline. The CLI emits `stream_event` lines containing Anthropic API events like `content_block_start` (with `type: "tool_use"`), `content_block_delta` (with `type: "input_json_delta"`), and `content_block_stop`. These are forwarded to the webview unchanged.

Tool results come back as `user` type events from the CLI (the CLI handles tool execution internally) and are also forwarded as `io_message` events.

## CSS/Theme System

The CC extension UI relies on hundreds of VSCode CSS custom properties for theming. Hangar replicates this with three layers:

### 1. VSCode Theme Variables (theme-light.css)

456 `--vscode-*` CSS variables exported from a real VSCode instance running the Default Light+ theme. These define all colors, fonts, borders, shadows, and other visual properties.

**Export process:**
1. Open VSCode with desired theme active
2. Run "Developer: Generate Color Theme From Current Settings" (Cmd+Shift+P)
3. Save the resulting JSON, strip JSONC comments
4. Convert JSON color definitions to CSS custom properties
5. Save as `theme-light.css`

### 2. App Bridge Variables

The CC extension CSS defines `--app-*` variables that map to `--vscode-*` variables, but some are not defined in the extension CSS and must be provided by the host:

```css
--app-code-background: var(--vscode-textCodeBlock-background);
--app-link-color: var(--vscode-textLink-foreground);
--app-font-family-mono: var(--vscode-editor-font-family, monospace);
--app-background: var(--vscode-editor-background);
--app-root-background: var(--vscode-sideBar-background);
--app-secondary-text: var(--vscode-descriptionForeground);
```

### 3. VSCode Default Webview CSS

VSCode injects a set of default styles into all webviews via a `@layer vscode-default` block. This includes:
- Scrollbar styling using `--vscode-scrollbarSlider-*` variables
- Body reset (margin, padding, background, font)
- Link colors (`--vscode-textLink-foreground`)
- Inline code styling (`--vscode-textPreformat-*`)
- Keyboard shortcut label styling (`--vscode-keybindingLabel-*`)
- Blockquote styling

### 4. Timeline CSS Fix

The CC extension's timeline view uses `::after` pseudo-elements with `position: absolute` for connecting lines between messages. Because Hangar's DOM structure differs slightly from VSCode's (each `timelineMessage` is also a `.message` with `position: relative`), the lines need a CSS fix:

```css
[class*="message_"][class*="timelineMessage_"]::after {
  bottom: -15px !important;
}
```

### Body Class

The `<body>` element must have `class="vscode-light"` (or `vscode-dark` for dark themes). The CC extension CSS uses this class for theme-specific overrides.

## WebView Setup Details

### Why loadFileURL Instead of loadHTMLString

`WKWebView.loadHTMLString` does not allow the webview to load local file resources (JS, CSS, images) via relative or absolute file URLs. The CC extension's `index.js` imports other modules and references assets using file paths, so `loadFileURL` is required.

The HTML is written to `~/Library/Application Support/Hangar/_hangar.html` and loaded with `allowingReadAccessTo` set to the user's home directory. This grants the webview read access to both the HTML file and the extension directory under `~/.vscode/extensions/`.

### Injected Scripts (atDocumentStart)

Two scripts are injected before any page content loads:

1. **Console capture** -- Overrides `console.log`, `console.error`, `console.warn` to forward messages to Swift via the `consoleLog` message handler. Also captures `window.onerror` and `window.onunhandledrejection`.

2. **VSCode API stub** -- Defines `window.acquireVsCodeApi()` which the CC extension calls to get its messaging API. The stub bridges `postMessage` to `window.webkit.messageHandlers.vscodeHost.postMessage`.

### Script Message Handlers

| Handler Name | Class | Purpose |
|-------------|-------|---------|
| `vscodeHost` | `WebViewMessageHandler` | Protocol messages (init, auth, launch, IO) |
| `consoleLog` | `ConsoleLogHandler` | JS console output -> os_log |

## Known Limitations and Workarounds

### No loadHTMLString

As described above, `loadHTMLString` cannot load local file resources. The workaround is writing an HTML file to disk and using `loadFileURL`.

### Timeline CSS Fix

The CC extension's CSS assumes a specific DOM nesting that differs slightly when rendered outside VSCode. The `::after` pseudo-elements used for timeline connecting lines need `bottom: -15px !important` to bridge a gap.

### --bare Flag

The `--bare` CLI flag skips keychain/OAuth authentication. It must NOT be used, as it breaks authentication.

### Content Array to String Conversion

The webview sends user messages with content as an array of blocks (`[{type:"text", text:"..."}]`), but the CLI's stream-json input expects content as a plain string. `WebViewMessageHandler` converts content arrays to joined text before forwarding.

### Auth Timing

Auth status is fetched asynchronously on init. If the webview's `init` request arrives before auth completes, the response will show unauthenticated state. The cached auth is available for subsequent `get_claude_state` requests.

### No Dark Mode

Only the light theme is currently supported. Adding dark mode requires exporting a second set of CSS variables from VSCode's dark theme and switching based on system appearance.
