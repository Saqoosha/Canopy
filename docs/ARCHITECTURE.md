# Architecture

> **⚠ Stale (as of 1.12.0):** the body of this document predates two
> migrations and is now wrong on both axes:
>
> 1. **Pre-sidebar:** `WindowGroup > AppState.screen` switching between a
>    launcher and a session view, plus `WindowTitleSetter` (deleted in
>    PR #48), no longer reflects reality. The shipping shell is a single
>    window with `NavigationSplitView`; `SessionStore` + `OpenSession`
>    own the shim / WKWebView refs; `Detail.swift` swaps the active
>    session subview in place.
> 2. **Pre-shim:** the System Overview diagram, the
>    `WebViewMessageHandler.swift` section, the `ClaudeProcess.swift`
>    section, and the Startup Sequence describe a Swift-side bridge
>    that talks directly to the Claude CLI. That layer was replaced
>    long ago by the Node.js vscode-shim subprocess. The real bridge
>    lives in `Sources/Canopy/ShimProcess.swift` plus the JS modules
>    under `Resources/vscode-shim/`. None of the files this doc names
>    (`WebViewMessageHandler.swift`, `ClaudeProcess.swift`) exist.
>
> See `CLAUDE.md` and the spec at
> `docs/superpowers/specs/2026-04-29-single-window-sidebar.md` for the
> current model. The body below is preserved as historical reference;
> a full rewrite is queued.

Detailed technical architecture of Canopy, a macOS app that hosts the Claude Code VSCode extension's webview in a native WKWebView and bridges it to a real Claude CLI process.

## System Overview

```
+------------------------------------------------------------------+
|  CanopyApp (SwiftUI)                                             |
|  WindowGroup > AppState (@Observable)                            |
|    ├─ .launcher → LauncherView (dir picker, sessions, perms)     |
|    └─ .session  → WebViewContainer (NSViewRepresentable)         |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |  WKWebView                                                 |  |
|  |                                                            |  |
|  |  Injected at document start:                               |  |
|  |    1. Console capture (log/error/warn -> consoleLog)       |  |
|  |    2. VSCodeStub (acquireVsCodeApi, IS_FULL_EDITOR, etc.)  |  |
|  |                                                            |  |
|  |  Loaded via loadFileURL(_canopy.html):                     |  |
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
|  |              --session-id <uuid> | --resume <session-id>     |  |
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

### CanopyApp.swift

SwiftUI `@main` entry point. Creates a `WindowGroup` that switches between `LauncherView` (directory picker) and `WebViewContainer` (chat) based on `AppState.screen`. Menu commands: Cmd+N (new session → launcher), Cmd+O (open folder → launch directly). Window title shows the current directory name via `WindowTitleSetter` (NSViewRepresentable helper).

### AppState.swift

`@Observable` class managing app-wide state:
- `screen` (`.launcher` | `.session`) — `private(set)`, transitions via `launchSession`/`backToLauncher`
- `workingDirectory` — selected project directory
- `permissionMode` — `PermissionMode` enum (`.default`, `.acceptEdits`, `.plan`, `.bypassPermissions`)
- `resumeSessionId` — session ID to resume (cleared after first use)
- `webviewReloadToken` — `private(set)`, incremented to force WebViewContainer recreation via `.id()`

### LauncherView.swift

SwiftUI welcome screen shown on app launch. Features:
- Directory selection via `NSOpenPanel` or drag-and-drop
- Permission mode picker bound to `AppState.permissionMode`
- Start button (Cmd+Enter) launches session
- Recent directories list (MRU, managed by `RecentDirectories`)
- Recent sessions list (loaded from `ClaudeSessionHistory.loadAllSessions()`)
- Search filter across directories and sessions
- Click on recent directory → immediate launch; click on session → resume with history

### ClaudeSessionHistory.swift

Reads Claude Code session data from `~/.claude/projects/`:
- `encodePath` — converts filesystem path to CLI's folder naming (replaces `/` and `.` with `-`)
- `loadSessions(for:)` — lists JSONL files in a project folder, extracts title (first user message, up to 8KB) and modification date
- `loadAllSessions()` — scans all project folders, reads `cwd` from JSONL metadata to get real paths (avoids lossy path decoding)
- `extractCwd` — reads first 4KB of a JSONL file to find the `cwd` field
- Filters out subagent files (`agent-*` prefix)

### RecentDirectories.swift

Caseless enum managing an MRU list of project directories in `UserDefaults`:
- Max 20 entries, deduplication on add, existence check on load
- API: `load()`, `add(_:)`, `remove(_:)`

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

Writes `_canopy.html` to `~/Library/Application Support/Canopy/` containing:
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

`dismantleNSView` calls `terminateAll()` on the handler (killing any running CLI processes), then removes all script message handlers and user scripts to prevent retain cycles between WKWebView and the handler objects.

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
| `list_sessions_request` | `list_sessions_response` | Real sessions from `~/.claude/projects/` |
| `request_usage_update` | `usage_update` | Always null |
| `login` | `login_response` | Opens claude.ai/login in browser, re-fetches auth |
| `open_url` | `open_url_response` | Opens URL in default browser via NSWorkspace |
| `open_help` | `open_help_response` | Opens Claude Code docs |
| `set_model` | Ack | No-op (not persisted) |
| `set_thinking_level` | Ack | No-op (not persisted) |
| `set_permission_mode` | Ack | Updates stored `PermissionMode` for subsequent launches |
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
- `terminateAll()` called during webview teardown to clean up all processes

**Session history replay:**
- When `launch_claude` is received with a resume session ID, `replaySessionHistory` runs before CLI launch
- Reads the session JSONL file, parses all `user`/`assistant`/`system` messages into a UUID-keyed map
- Walks the `parentUuid` chain backwards from the leaf node (naturally stops at `compact_boundary` where `parentUuid=nil`)
- Filters out sidechains, meta messages, and team messages
- Sends only `user`/`assistant` messages (system messages like `compact_boundary` are for chain structure only)
- All messages are serialized into a single JSON array and dispatched via synchronous `dispatchEvent(new MessageEvent(...))` — not `postMessage` — so React batches all state updates into a single render (instant display)

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
- `--session-id` -- Generated UUID for new sessions
- `--resume` -- Resume an existing session by ID (used when replaying history)

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
1. CanopyApp creates WindowGroup with AppState
2. LauncherView shown (AppState.screen == .launcher)
   a. Load recent directories from UserDefaults
   b. Load session history from ~/.claude/projects/ (background Task)
   c. User picks directory, permission mode, and optionally a session to resume
   d. launchSession() → AppState.screen = .session → SwiftUI recreates view
3. WebViewContainer.makeNSView:
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
   c. Write _canopy.html to ~/Library/Application Support/Canopy/
   d. loadFileURL with read access to home directory
5. Webview boots:
   a. React app mounts in <div id="root">
   b. acquireVsCodeApi() returns stub with postMessage bridge
   c. Extension sends: init -> get_claude_state -> get_asset_uris -> list_sessions
   d. Extension auto-launches claude (launch_claude message)
6. Session history replay (if resuming):
   a. Read JSONL file from ~/.claude/projects/{encoded-path}/
   b. Parse messages, build UUID map
   c. Walk parentUuid chain from leaf node
   d. Batch dispatch via dispatchEvent (single render)
7. ClaudeProcess spawned:
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

The CC extension UI relies on hundreds of VSCode CSS custom properties for theming. Canopy replicates this environment and layers custom styles on top to refine the UI for a native macOS feel.

### Loading Order

The HTML assembled in `WebViewContainer.loadCCWebview` loads stylesheets in this order — later layers override earlier ones:

```
1. theme-light.css          (inline <style>)    — 456 --vscode-* CSS variables
2. CC extension index.css   (linked <link>)     — extension's own styles
3. canopy-overrides.css     (inline <style>)    — custom overrides & WKWebView fixes
4. prism-canopy.css         (inline <style>)    — syntax highlighting theme
```

Bundled CSS files (canopy-overrides, prism-canopy) are read from `Bundle.main` and inlined into the HTML because the app bundle path (`/Applications/`) is outside the WKWebView's `allowingReadAccessTo` scope (home directory only).

### Layer 1: VSCode Theme Variables (`theme-light.css`)

456 `--vscode-*` CSS variables exported from a real VSCode instance running the Default Light+ theme. These define all colors, fonts, borders, shadows, and other visual properties that the CC extension CSS references.

**Export process:**
1. Open VSCode with desired theme active
2. Run "Developer: Generate Color Theme From Current Settings" (Cmd+Shift+P)
3. Save the resulting JSON, strip JSONC comments
4. Convert JSON color definitions to CSS custom properties
5. Save as `Sources/Canopy/theme-light.css`

### Layer 2: CC Extension Styles (`index.css`)

The extension's own stylesheet, linked from its install directory (`~/.vscode/extensions/anthropic.claude-code-*/webview/index.css`). Loaded unmodified via `<link>` tag — no Canopy changes.

### Layer 3: Custom Overrides (`canopy-overrides.css`)

Loaded after the extension's CSS so it can override specific styles. Uses `!important` or higher specificity where needed. This is the primary customization layer, organized into several sections:

#### Root Variables

Overrides `--vscode-*` variables from theme-light.css with values matching Claude Desktop's appearance (white backgrounds, adjusted foreground colors):

```css
--vscode-sideBar-background: #ffffff !important;
--vscode-editor-background: #ffffff !important;
--vscode-editor-foreground: #141413 !important;
```

Also provides `--app-*` bridge variables that the CC extension CSS expects but doesn't define itself:

```css
--app-code-background: #f5f5f0;
--app-link-color: var(--vscode-textLink-foreground);
--app-font-family-mono: var(--vscode-editor-font-family, monospace);
--app-background: var(--vscode-editor-background);
--app-root-background: var(--vscode-sideBar-background);
--app-secondary-text: var(--vscode-descriptionForeground);
```

#### VSCode Default Webview CSS (`@layer vscode-default`)

VSCode normally injects a set of default styles into all webviews. Since Canopy hosts the webview directly, this layer is replicated manually:

- Scrollbar styling using `--vscode-scrollbarSlider-*` variables
- Body reset (margin, padding, background, font)
- Link colors (`--vscode-textLink-foreground`)
- Inline `code` styling (background, border, border-radius, font)
- Keyboard shortcut label styling (`--vscode-keybindingLabel-*`)
- Blockquote styling

#### Timeline Fix

The CC extension's timeline uses `::after` pseudo-elements for connecting lines between messages. Each `timelineMessage` is also a `.message` (which has `position: relative`), creating a 15px gap. Fix:

```css
[class*="message_"][class*="timelineMessage_"]::after {
  bottom: -15px !important;
}
```

#### WKWebView Fixes

Fixes for WebKit-specific rendering differences from Chromium (which VSCode uses):

- **contenteditable `<br>`**: WKWebView doesn't render `<br>` in contenteditable without `white-space: pre-wrap`
- **Font smoothing**: WebKit's default is heavier than Chromium — `-webkit-font-smoothing: antialiased` matches VSCode's rendering

#### Typography

Message text and input fields use macOS system fonts with refined sizing:

- Timeline/user messages: `system-ui, -apple-system`, 14px, line-height 22px, weight 430
- Input fields: same font family/size but no line-height override (causes caret drift in WKWebView contenteditable)
- Headings (h1–h3): normalized to 14px/600 weight (CC extension sizes vary)
- Links in messages: dark color (`rgb(61, 61, 58)`) with underline instead of bright blue
- Font ligatures disabled on all code elements (`font-variant-ligatures: none`)

#### Code Blocks

Wrapper-based styling that matches Claude Desktop's appearance:

- Border: `1px solid rgba(31, 30, 29, 0.15)`, border-radius 8px
- Background: `rgba(250, 249, 245, 0.5)` (warm off-white)
- Inner `pre`: transparent background, no padding (handled by wrapper)
- Font: SF Mono 13px, line-height 20px

#### Inline Code

Styled with higher specificity to override both the extension and `@layer vscode-default`:

- Color: `rgb(138, 36, 36)` (dark red, matching VSCode's Default Light+)
- Background: warm off-white with subtle border
- `pre code` reset: transparent background, no border (code blocks handle their own styling)

#### Misc

- Todo checkbox alignment: `margin-top: 5.5px` to vertically center the 11px checkbox within 22px line-height
- Truncation gradient: overrides extension's hardcoded dark `#1e1e1e` gradient with the current editor background
- Tool result backgrounds: set to transparent

### Layer 4: Syntax Highlighting (`prism-canopy.css`)

Prism.js token colors matching Claude Desktop Code's appearance. Applied to code blocks where Prism.js has tokenized the content (injected via bundled `prism.js`).

Key color assignments:

| Token | Color | Example |
|-------|-------|---------|
| Comments | `rgb(110, 118, 135)` | `// comment` |
| Keywords | `rgb(129, 0, 194)` | `const`, `if`, `return` |
| Strings | `rgb(0, 128, 0)` | `"hello"` |
| Functions | `rgb(0, 81, 194)` | `myFunction()` |
| Numbers | `rgb(0, 128, 128)` | `42` |
| Parameters | `rgb(184, 79, 5)` | function args |
| Classes | `rgb(179, 74, 0)` | `MyClass` |

### Monaco Theme Patch (`VSCodeStub.swift`)

The CC extension hardcodes `theme: "vs-dark"` when creating Monaco diff editors. Since Canopy runs in light mode, a JavaScript patch redefines the `vs-dark` theme as a light theme:

```javascript
globalThis.MonacoEnvironment = { globalAPI: true };
monaco.editor.defineTheme('vs-dark', { base: 'vs', inherit: true, rules: [], colors: {} });
```

This runs via a `setInterval` poll (50ms) until Monaco loads, with a 30s timeout.

### Japanese IME Fix (`VSCodeStub.swift`)

WebKit Bug 165004: `compositionend` fires before `keydown`, so `isComposing` is always false for the Enter key that confirms IME input. Canopy patches `isComposing` to `true` when `keyCode === 229` (VK_PROCESS), which WebKit sets for all IME keydowns. This prevents the CC extension from submitting the message on IME-confirming Enter.

### Body Class

The `<body>` element must have `class="vscode-light"` (or `vscode-dark` for dark themes). The CC extension CSS uses this class for theme-specific overrides.

## WebView Setup Details

### Why loadFileURL Instead of loadHTMLString

`WKWebView.loadHTMLString` does not allow the webview to load local file resources (JS, CSS, images) via relative or absolute file URLs. The CC extension's `index.js` imports other modules and references assets using file paths, so `loadFileURL` is required.

The HTML is written to `~/Library/Application Support/Canopy/_canopy.html` and loaded with `allowingReadAccessTo` set to the user's home directory. This grants the webview read access to both the HTML file and the extension directory under `~/.vscode/extensions/`.

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

### Session Resume Does Not Replay CLI History

The `--resume` CLI flag reconnects to a session but does not replay history to stdout. Canopy reads the JSONL file directly and replays messages to the webview via `dispatchEvent`. This is the same approach as the VSCode extension (which also reads JSONL directly rather than relying on CLI output).

### dispatchEvent vs postMessage for History Replay

`window.postMessage()` is asynchronous — each call creates a separate microtask, causing React to re-render after each message (progressive rendering). `window.dispatchEvent(new MessageEvent('message', {data}))` is synchronous — all handlers fire inline within the same JS task, allowing React to batch all state updates into a single render. This makes history replay appear instant.

### No Dark Mode

Only the light theme is currently supported. Adding dark mode requires exporting a second set of CSS variables from VSCode's dark theme and switching based on system appearance.
