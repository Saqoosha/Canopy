# VSCode Shim: Run CC Extension Natively Without Protocol Reimplementation

**Date:** 2026-03-29
**Status:** Approved design, pending implementation

## Problem

Hangar currently reimplements the CC extension's host-side protocol in Swift (`WebViewMessageHandler.swift`, 1409 lines). Every time the CC extension updates — new message types, changed payload formats, new features (MCP, plugins, etc.) — the Swift code must be manually updated to match.

The extension (v2.1.87 at time of analysis) handles ~78 message types. The current Swift implementation covers ~42. This gap grows with each release.

## Solution

Run the CC extension's `extension.js` as-is in a Node.js subprocess, with a thin `vscode` module shim that bridges the extension's webview I/O to Hangar's WKWebView via stdio.

**Key insight:** `extension.js` uses 33 Node.js built-in modules (child_process, fs, path, os, http, crypto, stream, etc.) which all work natively in Node.js. Only the `vscode` module needs to be shimmed.

## Architecture

```
┌─ macOS App (Swift) ──────────────────────────────────┐
│                                                       │
│  LauncherView (SwiftUI)         ← stays in Swift     │
│    ├─ Directory picker, recent dirs, drag & drop      │
│    ├─ Session history (reads JSONL directly)           │
│    └─ User selects session → transitions to chat      │
│                                                       │
│  SessionView                                          │
│    ├─ WKWebView (CC extension webview/index.js)       │
│    │    ├─ acquireVsCodeApi() stub (existing)          │
│    │    └─ postMessage ↔ WKScriptMessageHandler        │
│    │                                                   │
│    └─ ShimProcess (replaces 1409-line                  │
│         WebViewMessageHandler)                         │
│         ├─ Spawns Node.js subprocess                   │
│         ├─ stdin: forwards webview messages to Node.js │
│         ├─ stdout: forwards Node.js messages to webview│
│         ├─ Handles host-side events (show_document,    │
│         │   show_notification, open_url, open_terminal)│
│         └─ Line-buffered stdout reader (handles split  │
│            reads and block buffering)                  │
│                                                       │
└───────────────────────────────────────────────────────┘
          │ stdio (NDJSON, one JSON object per line)
          ▼
┌─ Node.js subprocess ─────────────────────────────────┐
│                                                       │
│  vscode-shim.js                                       │
│    ├─ Redirects console.log/warn/error to stderr       │
│    ├─ Intercepts require("vscode") via Module hook     │
│    ├─ Webview bridge: stdin/stdout ↔ postMessage       │
│    ├─ ExtensionContext, globalState, subscriptions      │
│    ├─ workspace, commands, window, Uri, EventEmitter   │
│    ├─ Proxy-based unknown API detection + logging      │
│    └─ Unimplemented APIs → warning log + graceful stub │
│                                                       │
│  extension.js (CC extension, ZERO modifications)       │
│    ├─ activate() runs full initialization              │
│    ├─ CLI spawn via child_process → works natively     │
│    ├─ Auth, sessions, MCP, plugins → all work          │
│    └─ Webview provider → shim bridges to stdin/stdout  │
│                                                       │
└───────────────────────────────────────────────────────┘
```

## Design Decisions

### Communication: stdio with NDJSON

Chosen over WebSocket or Unix domain socket for SSH remote compatibility.

- **Local:** `Process("node", ["vscode-shim.js", "--cwd", "/path"])`
- **Remote:** `Process("ssh", ["-T", "user@host", "node", "vscode-shim.js", "--cwd", "/remote/path"])`
- Same protocol in both cases. SSH connection IS the transport.

No port management, no firewall issues, no connection timing complexity.

### stdout Isolation

**Critical:** extension.js and its dependencies use `console.log` which writes to stdout by default, corrupting the NDJSON stream. The shim MUST redirect all console output to stderr at startup:

```js
// First thing in vscode-shim.js — before any require()
console.log = (...args) => process.stderr.write('[ext:log] ' + args.join(' ') + '\n');
console.warn = (...args) => process.stderr.write('[ext:warn] ' + args.join(' ') + '\n');
console.error = (...args) => process.stderr.write('[ext:error] ' + args.join(' ') + '\n');
```

Swift reads stderr via a separate pipe for debug logging (same pattern as existing `ClaudeProcess.swift`).

### stdout Buffering

When stdout is a pipe (not a terminal), Node.js uses 16KB block buffering. This means NDJSON lines may be split across reads or multiple lines concatenated in one read.

- **Swift side:** Must maintain a line buffer. Accumulate `availableData`, split on `\n`, parse complete lines only. Carry incomplete trailing data to next read. (Same pattern as existing `ClaudeProcess.swift`.)
- **Node.js side:** Use `process.stdout.write(JSON.stringify(msg) + '\n')` (not `console.log`).

### Launcher stays in Swift

The launcher screen (directory picker, session history, recent dirs, drag & drop) remains SwiftUI. It's stable, fast, and a core Hangar differentiator. Node.js process is spawned only after session selection, keeping app startup instant.

### Module interception via Module._resolveFilename

```js
const Module = require("module");
const originalResolve = Module._resolveFilename;
Module._resolveFilename = function(request, parent, ...args) {
  if (request === "vscode") return "__vscode_shim__";
  return originalResolve.call(this, request, parent, ...args);
};
Module._cache["__vscode_shim__"] = { exports: vscodeShim };
```

This allows `extension.js` to run completely unmodified. No patching, no bundling.

**Note:** `Module._resolveFilename` is a Node.js internal (underscore-prefixed) API. It is widely used in the ecosystem and stable in practice, but not guaranteed across major versions. If CC extension migrates to ESM in the future, an alternative approach using `module.register()` (Node.js 20.6+) or `--loader` flag would be needed. The shim should detect the module format at startup and choose the appropriate interception method.

## stdio Protocol

### Ready Handshake

Startup involves a three-way ready sequence to prevent message loss:

```
1. Swift spawns Node.js process
2. Node.js initializes shim → calls extension.activate() → sends: {"type":"ready"}
3. Swift receives "ready" → starts forwarding stdin (buffered webview messages)
4. WKWebView finishes loading → Swift sends: {"type":"webview_ready"}
5. Node.js receives "webview_ready" → flushes any buffered postMessage calls

Before "ready": Swift buffers all webview→stdin messages
Before "webview_ready": Node.js buffers all postMessage→stdout messages
```

### Swift → Node.js (stdin)

```jsonl
{"type":"webview_message","message":{...}}
{"type":"webview_ready"}
{"type":"notification_response","requestId":"abc","buttonValue":"OK"}
```

Note: `cwd`, `resume`, and `permissionMode` are passed as CLI arguments at process spawn time, not via stdin. The stdin channel is exclusively for runtime messages. Swift writes to stdin on a background DispatchQueue to avoid main thread blocking from pipe backpressure.

### Node.js → Swift (stdout)

```jsonl
{"type":"ready"}
{"type":"webview_message","message":{...}}
{"type":"show_document","content":"...","fileName":"output.txt"}
{"type":"show_notification","message":"...","severity":"error","buttons":["OK","Cancel"],"requestId":"abc"}
{"type":"open_url","url":"https://..."}
{"type":"open_terminal","executable":"claude","args":["--resume","xxx"],"cwd":"/path"}
{"type":"log","level":"warn","msg":"..."}
{"type":"error","message":"activate() failed: ...","stack":"..."}
```

Swift wraps `webview_message` payloads in `{type: "from-extension", message: ...}` before forwarding to WKWebView. All other types are handled natively by Swift.

## vscode API Implementation

### Tier 1: Required for chat functionality

| API | Implementation |
|-----|---------------|
| `window.registerWebviewViewProvider` | Calls provider's `resolveWebviewView`, passes webview object bridged to stdin/stdout |
| `window.createWebviewPanel` | Same bridge. Plan preview panel (`claudePlanPreview`) is a secondary webview — stubbed in Phase 1, routed to same bridge later |
| `webview.postMessage(msg)` | Writes `{"type":"webview_message","message":msg}` to stdout |
| `webview.onDidReceiveMessage` | Fires when `{"type":"webview_message",...}` arrives on stdin |
| `webview.html` setter | Ignored — Hangar independently loads the webview's `index.js`/`index.css` via `_hangar.html` in WKWebView. The extension's HTML assignment is redundant because the native webview is already rendering the same React app |
| `webview.asWebviewUri(uri)` | Returns file URI unchanged |
| `webview.cspSource` | Returns `""` |
| `webview.visible` | `true` |
| `webview.onDidChangeVisibility` | No-op event (always visible) |
| `commands.registerCommand(id, fn)` | Stores in Map |
| `commands.executeCommand(id, ...args)` | `setContext` → stores in Map; others → calls registered handler or no-op |
| `workspace.getConfiguration(section)` | Returns config object with `get(key, default)`, `has(key)`, `update(key, value, target)`, `inspect(key)`. Values from: (1) `~/Library/Application Support/Hangar/settings.json`, (2) extension's `package.json` `contributes.configuration` defaults, (3) fallback to undefined. `update()` persists to settings.json |
| `workspace.workspaceFolders` | Generated from `--cwd` argument |
| `workspace.findFiles(pattern, exclude, limit)` | Uses recursive `fs.readdir` with pattern matching (not `fs.glob` which requires Node 22+). Fallback for ripgrep-based @mention file search |
| `ExtensionContext.globalState` | `get()`/`update()` backed by JSON file in `~/Library/Application Support/Hangar/` |
| `ExtensionContext.subscriptions` | Array of disposables |
| `ExtensionContext.extensionPath` / `extensionUri` | From `--extension-path` argument |
| `ExtensionContext.extension.id` | `"anthropic.claude-code"` |
| `Uri.file()`, `Uri.joinPath()`, `Uri.parse()`, `Uri.from()` | Path/URI manipulation |
| `EventEmitter` | `fire()`, `.event` property, listener management |
| `ViewColumn`, `StatusBarAlignment`, `ConfigurationTarget` etc. | Numeric enum constants |
| `env.appName` | `"Visual Studio Code"` — extension may branch on this value; returning the expected name avoids feature gating issues. Investigate actual branching behavior during implementation |
| `env.uiKind` | `UIKind.Desktop` (1) |
| `env.openExternal(uri)` | Writes `{"type":"open_url","url":"..."}` to stdout |
| `env.shell` | `process.env.SHELL` |
| `env.remoteName` | `undefined` (local) or SSH host name (remote). Extension uses `!env.remoteName` to gate `includePartialMessages` |
| `window.showInformationMessage(msg, ...buttons)` | Writes `{"type":"show_notification","severity":"info",...}` to stdout; returns Promise. 60-second timeout resolves with `undefined` (cancel) if no response. See Notification Protocol below |
| `window.showErrorMessage(msg, ...buttons)` | Same, severity `"error"` |
| `window.showWarningMessage(msg, ...buttons)` | Same, severity `"warning"` |
| `workspace.openTextDocument({content, language})` | Returns virtual document object with content and languageId |
| `window.showTextDocument(doc, options)` | Writes `{"type":"show_document","content":"...","fileName":"..."}` to stdout |

### Notification Protocol

Notifications with buttons require a response roundtrip:

```
Node.js → stdout: {"type":"show_notification","severity":"error","message":"...","buttons":["A","B"],"requestId":"n1"}
Swift shows NSAlert → user clicks "A" or dismisses
Swift → stdin: {"type":"notification_response","requestId":"n1","buttonValue":"A"}
  (or buttonValue: null if dismissed without clicking a button)
```

**Timeout:** If no response within 60 seconds, the Promise resolves with `undefined` (same as user cancelling). This prevents extension.js from hanging indefinitely.

**Multiple notifications:** Node.js maintains a pending notification Map keyed by requestId. All pending notifications are rejected on process exit.

### Tier 2: Graceful stubs (no-op or minimal)

**Stub policy:** Stubs should return "failure" or "empty" values, never "success". A stub that reports success (e.g., `applyEdit() → true`) is worse than one that reports failure — it silently hides the fact that nothing happened. When a stub is first called, it logs a warning to stderr AND sends `{"type":"log","level":"warn","msg":"Stub called: <api>"}` to stdout (once per API, not per call).

| API | Stub behavior | Reason safe to stub |
|-----|--------------|-------------------|
| `window.activeTextEditor` | `undefined` | No editor in Hangar |
| `window.visibleTextEditors` | `[]` | No editor |
| `window.terminals` | `[]` | No embedded terminal |
| `window.tabGroups` | `{all: []}` | No tabs |
| `window.createStatusBarItem()` | `{text:"",show(){},hide(){},dispose(){}}` | No status bar |
| `window.createOutputChannel(name)` | Object with methods that write to stderr | Debug only |
| `window.createTerminal(opts)` | Writes `{"type":"open_terminal",...}` to stdout | Swift opens Terminal.app |
| `window.withProgress(opts, fn)` | `fn({report(){}}, {isCancellationRequested:false, onCancellationRequested:()=>({dispose(){}})})` | Passes required progress/token args |
| `window.showQuickPick()` | `Promise.resolve(undefined)` + warn log | Currently Jupyter only. Future: may need native picker bridge |
| `window.showInputBox()` | `Promise.resolve(undefined)` + warn log | Currently plugin install only |
| `window.registerUriHandler()` | No-op disposable | VSCode URI scheme |
| `window.registerWebviewPanelSerializer()` | No-op | VSCode panel restore |
| `window.onDidChangeActiveTextEditor` | No-op event | No editor |
| `window.onDidChangeVisibleTextEditors` | No-op event | No editor |
| `window.onDidChangeTextEditorSelection` | No-op event | No editor |
| `window.onDidStartTerminalShellExecution` | No-op event | No terminal |
| `window.onDidEndTerminalShellExecution` | No-op event | No terminal |
| `window.onDidChangeTerminalShellIntegration` | No-op event | No terminal |
| `window.activeTerminal` | `undefined` | No terminal |
| `window.activeNotebookEditor` | `undefined` | No notebooks |
| `workspace.registerFileSystemProvider()` | No-op disposable | Diff editor FS (VSCode-specific) |
| `workspace.registerTextDocumentContentProvider()` | No-op disposable | Read-only content (VSCode-specific) |
| `workspace.textDocuments` | `[]` | No open documents |
| `workspace.onDidChangeTextDocument` | No-op event | Diff tracking (VSCode-specific) |
| `workspace.onDidSaveTextDocument` | No-op event | Diff save (VSCode-specific) |
| `workspace.onWillSaveTextDocument` | No-op event | Pre-save hook |
| `workspace.onDidChangeConfiguration` | No-op event | Hangar manages config independently |
| `workspace.onDidChangeWorkspaceFolders` | No-op event | Static workspace |
| `workspace.asRelativePath(path)` | `path.relative(cwd, path)` | Simple path math |
| `workspace.getWorkspaceFolder(uri)` | Returns first workspace folder | Single-folder workspace |
| `workspace.applyEdit()` | `Promise.resolve(false)` | Returns false (edit not applied), not true |
| `workspace.fs.stat()` | `fs.promises.stat()` wrapper | MCP tool file check |
| `workspace.workspaceFile` | `undefined` | No multi-root workspace |
| `workspace.rootPath` | Same as `workspaceFolders[0].uri.fsPath` | Legacy API |
| `languages.getDiagnostics()` | `[]` | No language server |
| `languages.onDidChangeDiagnostics` | No-op event | No language server |
| `extensions.getExtension()` | `undefined` | No other extensions |
| `env.clipboard.readText()` | `Promise.resolve("")` | Terminal content hack only |
| `env.clipboard.writeText()` | `Promise.resolve()` | Terminal content hack only |
| `env.machineId` | `crypto.randomUUID()` (generated once, persisted) | Telemetry identifier |
| `env.sessionId` | `crypto.randomUUID()` (per process) | Session identifier |
| `version` | `"1.100.0"` | Satisfies version checks |
| `Disposable` | `new Disposable(fn)` → `{dispose: fn}` | Standard pattern |
| `Selection`, `Range`, `Position` | Simple data classes | Minimal usage |
| `RelativePattern` | `{base, pattern}` | For findFiles |
| `TabInputText`, `TabInputTextDiff`, `TabInputWebview` | Classes for `instanceof` checks | Always returns false (empty tabGroups) |
| `FileSystemError` | Error subclasses | For FS provider stubs |
| `FileType`, `FileChangeType` | Numeric enums | For FS provider stubs |
| `TextEditorRevealType` | Numeric enum | No editor |
| `TextDocumentChangeReason` | Numeric enum | No editor |
| `DiagnosticSeverity` | Numeric enum | No diagnostics |
| `NotebookCellOutputItem`, `NotebookCellData`, `NotebookCellKind`, `NotebookEdit`, `NotebookEditorRevealType`, `NotebookRange` | Minimal stubs | Jupyter only |
| `WorkspaceEdit` | `{set(){}}` | Jupyter only |
| `ExtensionContext.logUri` / `logPath` | Path under `~/Library/Application Support/Hangar/logs/` | Activation may reference it |

### Unknown API Detection

The shim uses a Proxy to detect and log access to APIs not listed in Tier 1 or 2:

```js
const vscodeShim = new Proxy(knownApis, {
  get(target, prop) {
    if (prop in target) return target[prop];
    const msg = `Unknown vscode API accessed: vscode.${String(prop)}`;
    process.stderr.write(`[vscode-shim] WARN: ${msg}\n`);
    writeStdout({ type: "log", level: "warn", msg });
    return undefined;
  }
});
```

This makes it easy to discover which new APIs a CC extension update requires.

### Tier 3: Future implementation (SSH remote / feature expansion)

| API | When needed |
|-----|-----------|
| `workspace.findFiles` (enhanced) | Improved @mention with glob, gitignore awareness |
| `workspace.fs.readFile/writeFile/stat` | Remote file operations over SSH |
| `languages.getDiagnostics` (real) | Remote LSP integration |
| `window.createTerminal` (real) | Embedded terminal in Hangar |
| `window.showQuickPick` (real) | Native picker bridge for MCP/model selection |
| `window.showInputBox` (real) | Native input bridge |
| `registerFileSystemProvider` (real) | In-app diff viewer |
| `workspace.openTextDocument(uri)` (file variant) | Remote file viewing |

## Swift-Side Changes

### New: ShimProcess

Replaces `WebViewMessageHandler.swift` (1409 lines) + `ClaudeProcess.swift` (387 lines). Responsibilities:

1. **Spawn Node.js:** `Process(nodePath, ["vscode-shim.js", "--extension-path", extensionPath, "--cwd", cwd, "--resume", sessionId, "--permission-mode", mode])`
2. **Forward webview→Node.js:** `WKScriptMessageHandler` → JSON serialize → write to stdin (on background DispatchQueue to avoid pipe backpressure blocking main thread)
3. **Forward Node.js→webview:** Read stdout with line buffer (accumulate data, split on `\n`, parse complete lines). Forward `webview_message` via `webView.evaluateJavaScript("window.postMessage({type:'from-extension',message:...})")`
4. **Handle host events:** `show_document` → ContentViewer, `show_notification` → NSAlert (with dismiss detection), `open_url` → NSWorkspace, `open_terminal` → Terminal.app
5. **Ready handshake:** Buffer webview messages until `{"type":"ready"}` received from Node.js. Send `{"type":"webview_ready"}` when WKWebView load completes.
6. **Lifecycle:** Start on session open, SIGTERM on session close/app quit. Track child PIDs for orphan cleanup.
7. **Crash recovery:** On unexpected process exit, show error banner. Offer restart with `--resume` to recover session. WKWebView is preserved (not reloaded) — Node.js re-sends session state via extension.js's normal initialization flow.

### Orphan Process Cleanup

When the Node.js process exits (especially on SIGKILL), its CLI child process may become orphaned:

1. Swift records the Node.js process PID at spawn time
2. On process exit, run `pgrep -P <pid>` to find surviving children
3. Send SIGTERM to children, wait 2 seconds, then SIGKILL if still alive
4. Node.js side also sets up cleanup: `process.on('exit', () => { try { process.kill(-process.pid, 'SIGTERM'); } catch {} })`

### Kept: Existing Swift components

| File | Status | Notes |
|------|--------|-------|
| `HangarApp.swift` | Keep | App entry, launcher ↔ session switching |
| `AppState.swift` | Keep | Observable state, screen transitions |
| `LauncherView.swift` | Keep | Launcher UI (core Hangar feature) |
| `WebViewContainer.swift` | Modify | Remove direct message handler setup, connect to ShimProcess |
| `VSCodeStub.swift` | Keep | acquireVsCodeApi() JS stub, theme CSS |
| `CCExtension.swift` | Keep | Extension/CLI path discovery |
| `ClaudeSessionHistory.swift` | Keep | Session JSONL parser for launcher |
| `RecentDirectories.swift` | Keep | MRU directory list |
| `ContentViewer.swift` | Keep | Monaco overlay viewer |
| `WebViewMessageHandler.swift` | **Delete** | Replaced by ShimProcess + vscode-shim.js |
| `ClaudeProcess.swift` | **Delete** | CLI spawning moves to extension.js |

### Node.js Discovery

1. Run `which node` or check `PATH` for `node`
2. Check common locations: `/usr/local/bin/node`, `/opt/homebrew/bin/node`
3. Check mise: run `mise which node` or look in `~/.local/share/mise/installs/node/*/bin/node`
4. Check nvm: `~/.nvm/versions/node/*/bin/node`
5. Use CC CLI's own Node.js if found (the CLI binary includes Node.js)
6. **Version check:** Run `node --version`, require >= 18.0.0. Show specific error if version is too old.
7. If not found → show error in launcher: "Node.js 18+ is required. Install via mise, nvm, or nodejs.org"

Log which Node.js path and version is being used for debugging.

## Data Flow Examples

### User sends a chat message

```
1. Webview sends launch_claude → extension.js spawns CLI
2. User types "Hello" → webview postMessage({type:"io_message", channelId:"ch1", message:{...}})

3. Swift WKScriptMessageHandler receives → writes to Node.js stdin:
   {"type":"webview_message","message":{"type":"io_message","channelId":"ch1","message":{...}}}

4. Node.js vscode shim fires onDidReceiveMessage on the webview provider
5. extension.js handles io_message → writes to CLI stdin
6. CLI responds with stream_event lines
7. extension.js calls webview.postMessage({type:"io_message",message:{type:"stream_event",...}})
8. vscode shim writes to stdout:
   {"type":"webview_message","message":{"type":"io_message","message":{type:"stream_event",...}}}

9. Swift reads stdout → wraps in from-extension → sends to WKWebView:
   window.postMessage({type:"from-extension", message:{type:"io_message",...}})

10. Webview renders streaming response
```

### Tool permission request (CLI asks user for approval)

```
1. CLI sends control request → extension.js receives
2. extension.js calls webview.postMessage({type:"request",request:{type:"tool_permission_request",...}})
3. shim → stdout → Swift → WKWebView
4. User clicks "Allow" → webview postMessage({type:"response",requestId:"...",response:{...}})
5. Swift → stdin → shim → onDidReceiveMessage → extension.js
6. extension.js sends response to CLI
```

### Show notification with buttons

```
1. CLI triggers show_notification
2. extension.js calls vscode.window.showErrorMessage("Terms updated", "Resolve")
3. shim writes: {"type":"show_notification","severity":"error","message":"Terms updated","buttons":["Resolve"],"requestId":"n1"}
4. Swift shows NSAlert with "Resolve" button
5a. User clicks "Resolve" → Swift writes to stdin:
    {"type":"notification_response","requestId":"n1","buttonValue":"Resolve"}
5b. Or user dismisses alert → Swift writes:
    {"type":"notification_response","requestId":"n1","buttonValue":null}
5c. Or 60s timeout → shim auto-resolves with undefined
6. shim resolves the Promise returned by showErrorMessage
7. extension.js handles the result
```

## Error Handling

### Node.js process crashes
- ShimProcess detects process exit via `terminationHandler`
- Show error banner in webview or native alert
- Offer "Restart" button → re-spawn Node.js with `--resume` flag for same session
- WKWebView is preserved (not reloaded) — session state restored via extension.js init
- Orphan CLI processes cleaned up via PID tracking (see Orphan Process Cleanup)

### Unimplemented vscode API called
- **Known stubs (Tier 2):** First call logs warning to stderr + sends `{"type":"log"}` to Swift (once per API)
- **Unknown APIs (not in Tier 1/2):** Proxy detects access, logs to stderr + Swift. Returns `undefined`
- Does NOT throw — extension continues running
- These warnings help discover which APIs a new extension version requires

### Extension.js throws during activate
- Shim catches both synchronous exceptions and async Promise rejections:
```js
try {
  const result = extension.activate(context);
  if (result && typeof result.then === 'function') await result;
} catch (err) {
  writeStdout({ type: "error", message: `activate() failed: ${err.message}`, stack: err.stack });
  process.exit(1);  // Don't continue in half-broken state
}
```
- Swift shows error in UI
- Common causes: extension version mismatch, missing files

### stdin/stdout stream corruption
- Each stdout line must be valid JSON (NDJSON)
- Invalid lines are logged to stderr and skipped (they originate from extension.js code that bypassed our console redirect, or from native addon output)
- Shim uses `readline` interface for line-by-line stdin parsing
- Swift uses line-buffered stdout reader (accumulate data, split on `\n`)

## Migration Path

1. **Phase 1:** Implement vscode-shim.js + ShimProcess.swift side by side with existing WebViewMessageHandler
2. **Phase 2:** Feature flag to switch between old (Swift) and new (shim) implementations
3. **Phase 3:** Validate all chat features work with shim
4. **Phase 4:** Remove WebViewMessageHandler.swift and ClaudeProcess.swift
5. **Phase 5:** Add SSH remote support (additional design work required — see SSH section)

## File Layout

```
Sources/Hangar/
  ShimProcess.swift          (NEW — replaces WebViewMessageHandler + ClaudeProcess)
  WebViewContainer.swift     (MODIFIED — connect to ShimProcess)
  ... (other files unchanged)

Resources/
  vscode-shim.js             (NEW — bundled in app, self-contained, no node_modules)
```

## Dependencies

- **Node.js >= 18.0.0:** Required on user's machine. Not bundled. CC CLI users already have it.
- **No npm packages:** vscode-shim.js is self-contained. Uses only Node.js built-ins.

## Success Criteria

1. All current Hangar chat features work (send message, streaming, tool use, permission prompts)
2. @file mention works (ripgrep-based file search via extension.js)
3. Session resume works
4. Extension updates require zero Hangar code changes (unless new vscode APIs are used — detected via Proxy warnings)
5. WebViewMessageHandler.swift (1409 lines) + ClaudeProcess.swift (387 lines) are deleted
6. App binary size unchanged (no Node.js bundled)

## Future: SSH Remote

With stdio transport, SSH remote shares the same NDJSON protocol. However, SSH remote requires additional design work beyond just changing the Process spawn command:

```swift
// Local
let process = Process()
process.executableURL = URL(fileURLWithPath: nodePath)
process.arguments = ["vscode-shim.js", "--extension-path", extPath, "--cwd", cwd]

// Remote (concept — needs additional design)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
process.arguments = ["-T", "\(user)@\(host)", "node", "vscode-shim.js",
                     "--extension-path", remoteExtPath, "--cwd", remoteCwd]
```

### Open issues for SSH remote (Phase 5 design work)

1. **Extension deployment:** CC extension must be installed on the remote host. Mechanism TBD (scp, auto-install via CLI, etc.)
2. **Shim deployment:** `vscode-shim.js` must be transferred to the remote machine
3. **globalState path:** `~/Library/Application Support/Hangar/` doesn't exist on Linux remotes. Use XDG paths or `~/.config/hangar/`
4. **Connection drop detection:** SSH stdio has no TCP keepalive. Require `ServerAliveInterval` SSH config or implement application-level heartbeat
5. **stderr mixing:** Remote Node.js stderr and SSH transport errors arrive on the same fd. Need prefix-based separation
6. **SSH banners/MOTD:** Can corrupt stdout. Require `-T` flag (no pseudo-terminal) and consider `-o LogLevel=ERROR`
