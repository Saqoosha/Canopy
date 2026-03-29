# VSCode Shim: Run CC Extension Natively Without Protocol Reimplementation

**Date:** 2026-03-29
**Status:** Approved design, pending implementation

## Problem

Hangar currently reimplements the CC extension's host-side protocol in Swift (`WebViewMessageHandler.swift`, 1409 lines). Every time the CC extension updates — new message types, changed payload formats, new features (MCP, plugins, etc.) — the Swift code must be manually updated to match.

The extension analysis (v2.1.87) revealed ~60+ message types, growing with each release. The current implementation only covers ~40.

## Solution

Run the CC extension's `extension.js` as-is in a Node.js subprocess, with a thin `vscode` module shim that bridges the extension's webview I/O to Hangar's WKWebView via stdio.

**Key insight:** `extension.js` uses 30+ Node.js built-in modules (child_process, fs, path, os, http, crypto, stream, etc.) which all work natively in Node.js. Only the `vscode` module needs to be shimmed.

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
│    └─ ShimProcess (~150 lines, replaces 1409-line      │
│         WebViewMessageHandler)                         │
│         ├─ Spawns Node.js subprocess                   │
│         ├─ stdin: forwards webview messages to Node.js │
│         ├─ stdout: forwards Node.js messages to webview│
│         └─ Handles host-side events (show_document,    │
│            show_notification, open_url, open_terminal) │
│                                                       │
└───────────────────────────────────────────────────────┘
          │ stdio (NDJSON, one JSON object per line)
          ▼
┌─ Node.js subprocess ─────────────────────────────────┐
│                                                       │
│  vscode-shim.js (~800 lines)                          │
│    ├─ Intercepts require("vscode") via Module hook     │
│    ├─ Webview bridge: stdin/stdout ↔ postMessage       │
│    ├─ ExtensionContext, globalState, subscriptions      │
│    ├─ workspace, commands, window, Uri, EventEmitter   │
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
- **Remote:** `Process("ssh", ["user@host", "node", "vscode-shim.js", "--cwd", "/remote/path"])`
- Same protocol in both cases. SSH connection IS the transport.

No port management, no firewall issues, no connection timing complexity.

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

## stdio Protocol

### Swift → Node.js (stdin)

```jsonl
{"type":"webview_message","message":{...}}
{"type":"notification_response","requestId":"abc","buttonValue":"OK"}
```

Note: `cwd`, `resume`, and `permissionMode` are passed as CLI arguments at process spawn time, not via stdin. The stdin channel is exclusively for runtime messages.

### Node.js → Swift (stdout)

```jsonl
{"type":"ready"}
{"type":"webview_message","message":{...}}
{"type":"show_document","content":"...","fileName":"output.txt"}
{"type":"show_notification","message":"...","severity":"error","buttons":["OK","Cancel"],"requestId":"abc"}
{"type":"notification_response","requestId":"abc","buttonValue":"OK"}
{"type":"open_url","url":"https://..."}
{"type":"open_terminal","executable":"claude","args":["--resume","xxx"],"cwd":"/path"}
{"type":"log","level":"info","msg":"..."}
```

Swift wraps `webview_message` payloads in `{type: "from-extension", message: ...}` before forwarding to WKWebView. All other types are handled natively by Swift.

## vscode API Implementation

### Tier 1: Required for chat functionality

| API | Implementation |
|-----|---------------|
| `window.registerWebviewViewProvider` | Calls provider's `resolveWebviewView`, passes webview object bridged to stdin/stdout |
| `window.createWebviewPanel` | Same bridge. Only first panel is active |
| `webview.postMessage(msg)` | Writes `{"type":"webview_message","message":msg}` to stdout |
| `webview.onDidReceiveMessage` | Fires when `{"type":"webview_message",...}` arrives on stdin |
| `webview.html` setter | Ignored (Hangar manages HTML independently) |
| `webview.asWebviewUri(uri)` | Returns file URI unchanged |
| `webview.cspSource` | Returns `""` |
| `commands.registerCommand(id, fn)` | Stores in Map |
| `commands.executeCommand(id, ...args)` | `setContext` → stores in Map; others → calls registered handler or no-op |
| `workspace.getConfiguration(section)` | Returns config values from JSON file or defaults |
| `workspace.workspaceFolders` | Generated from `--cwd` argument |
| `workspace.findFiles(pattern, exclude, limit)` | Delegates to `fs.glob` or spawns `find`. Fallback for ripgrep-based @mention search |
| `ExtensionContext.globalState` | `get()`/`update()` backed by JSON file in `~/Library/Application Support/Hangar/` |
| `ExtensionContext.subscriptions` | Array of disposables |
| `ExtensionContext.extensionPath` / `extensionUri` | From `--extension-path` argument |
| `ExtensionContext.extension.id` | `"anthropic.claude-code"` |
| `Uri.file()`, `Uri.joinPath()`, `Uri.parse()`, `Uri.from()` | Path/URI manipulation |
| `EventEmitter` | `fire()`, `.event` property, listener management |
| `ViewColumn`, `StatusBarAlignment`, `ConfigurationTarget` etc. | Numeric enum constants |
| `env.appName` | `"Hangar"` |
| `env.uiKind` | `UIKind.Desktop` (1) |
| `env.openExternal(uri)` | Writes `{"type":"open_url","url":"..."}` to stdout |
| `env.shell` | `process.env.SHELL` |
| `env.remoteName` | `undefined` (local) or SSH host name (remote) |
| `window.showInformationMessage(msg, ...buttons)` | Writes `{"type":"show_notification","severity":"info",...}` to stdout; returns Promise that resolves when Swift sends response via stdin |
| `window.showErrorMessage(msg, ...buttons)` | Same, severity `"error"` |
| `window.showWarningMessage(msg, ...buttons)` | Same, severity `"warning"` |
| `workspace.openTextDocument({content, language})` | Returns virtual document object with content and languageId |
| `window.showTextDocument(doc, options)` | Writes `{"type":"show_document","content":"...","fileName":"..."}` to stdout |

### Tier 2: Graceful stubs (no-op or minimal)

| API | Stub behavior | Reason safe to stub |
|-----|--------------|-------------------|
| `window.activeTextEditor` | `undefined` | No editor in Hangar |
| `window.visibleTextEditors` | `[]` | No editor |
| `window.terminals` | `[]` | No embedded terminal |
| `window.tabGroups` | `{all: []}` | No tabs |
| `window.createStatusBarItem()` | `{text:"",show(){},hide(){},dispose(){}}` | No status bar |
| `window.createOutputChannel(name)` | Wraps `console.log` | Debug only |
| `window.createTerminal(opts)` | Writes `{"type":"open_terminal",...}` to stdout | Swift opens Terminal.app |
| `window.withProgress(opts, fn)` | Calls `fn` immediately | Only splash notification |
| `window.showQuickPick()` | `Promise.resolve(undefined)` | Jupyter only |
| `window.showInputBox()` | `Promise.resolve(undefined)` | Plugin install only |
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
| `workspace.applyEdit()` | `Promise.resolve(true)` | Jupyter only |
| `workspace.fs.stat()` | `fs.promises.stat()` wrapper | MCP tool file check |
| `workspace.workspaceFile` | `undefined` | No multi-root workspace |
| `workspace.rootPath` | Same as `workspaceFolders[0].uri.fsPath` | Legacy API |
| `languages.getDiagnostics()` | `[]` | No language server |
| `languages.onDidChangeDiagnostics` | No-op event | No language server |
| `extensions.getExtension()` | `undefined` | No other extensions |
| `env.clipboard.readText()` | `Promise.resolve("")` | Terminal content hack only |
| `env.clipboard.writeText()` | `Promise.resolve()` | Terminal content hack only |
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

### Tier 3: Future implementation (SSH remote / feature expansion)

| API | When needed |
|-----|-----------|
| `workspace.findFiles` (enhanced) | Improved @mention with glob, gitignore awareness |
| `workspace.fs.readFile/writeFile/stat` | Remote file operations over SSH |
| `languages.getDiagnostics` (real) | Remote LSP integration |
| `window.createTerminal` (real) | Embedded terminal in Hangar |
| `registerFileSystemProvider` (real) | In-app diff viewer |
| `workspace.openTextDocument(uri)` (file variant) | Remote file viewing |

## Swift-Side Changes

### New: ShimProcess (~150 lines)

Replaces `WebViewMessageHandler.swift` (1409 lines). Responsibilities:

1. **Spawn Node.js:** `Process("/usr/local/bin/node", ["vscode-shim.js", "--extension-path", extensionPath, "--cwd", cwd])`
2. **Forward webview→Node.js:** `WKScriptMessageHandler` → JSON serialize → write to stdin
3. **Forward Node.js→webview:** Read stdout lines → parse JSON → `webView.evaluateJavaScript("window.postMessage({type:'from-extension',message:...})")`
4. **Handle host events:** `show_document` → ContentViewer, `show_notification` → NSAlert/UNUserNotification, `open_url` → NSWorkspace, `open_terminal` → Terminal.app
5. **Lifecycle:** Start on session open, kill on session close/app quit

### Kept: Existing Swift components

| File | Status | Notes |
|------|--------|-------|
| `HangarApp.swift` | Keep | App entry, launcher ↔ session switching |
| `AppState.swift` | Keep | Observable state, screen transitions |
| `LauncherView.swift` | Keep | Launcher UI (core Hangar feature) |
| `WebViewContainer.swift` | Modify slightly | Remove direct message handler setup, connect to ShimProcess |
| `VSCodeStub.swift` | Keep | acquireVsCodeApi() JS stub, theme CSS |
| `CCExtension.swift` | Keep | Extension/CLI path discovery |
| `ClaudeSessionHistory.swift` | Keep | Session JSONL parser for launcher |
| `RecentDirectories.swift` | Keep | MRU directory list |
| `ContentViewer.swift` | Keep | Monaco overlay viewer |
| `WebViewMessageHandler.swift` | **Delete** | Replaced by ShimProcess + vscode-shim.js |
| `ClaudeProcess.swift` | **Delete** | CLI spawning moves to extension.js |

### Node.js Discovery

1. Check `process.env.PATH` for `node`
2. Check common locations: `/usr/local/bin/node`, `/opt/homebrew/bin/node`, `~/.nvm/...`, `~/.mise/...`
3. Use CC CLI's own Node.js if found (the CLI binary includes Node.js)
4. If not found → show error in launcher: "Node.js is required"

## Data Flow Examples

### User sends a chat message

```
1. User types "Hello" → webview postMessage({type:"request", requestId:"r1",
     request:{type:"io_message", channelId:"ch1", message:{role:"user",content:[{type:"text",text:"Hello"}]}}})
   (actually the webview sends launch_claude first, then io_message directly)

2. Swift WKScriptMessageHandler receives → writes to Node.js stdin:
   {"type":"webview_message","message":{"type":"io_message","channelId":"ch1","message":{...}}}

3. Node.js vscode shim fires onDidReceiveMessage on the webview provider
4. extension.js handles io_message → writes to CLI stdin
5. CLI responds with stream_event lines
6. extension.js calls webview.postMessage({type:"io_message",message:{type:"stream_event",...}})
7. vscode shim writes to stdout:
   {"type":"webview_message","message":{"type":"io_message","message":{type:"stream_event",...}}}

8. Swift reads stdout → wraps in from-extension → sends to WKWebView:
   window.postMessage({type:"from-extension", message:{type:"io_message",...}})

9. Webview renders streaming response
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
5. User clicks "Resolve" → Swift writes to stdin:
   {"type":"notification_response","requestId":"n1","buttonValue":"Resolve"}
6. shim resolves the Promise returned by showErrorMessage with "Resolve"
7. extension.js handles the button click (e.g., opens terminal)
```

## Error Handling

### Node.js process crashes
- ShimProcess detects process exit
- Show error banner in webview or native alert
- Offer "Restart" button → re-spawn Node.js process with same session
- CLI process (child of Node.js) is automatically killed

### Unimplemented vscode API called
- Shim logs warning to stderr: `[vscode-shim] WARN: window.createTreeView not implemented`
- Returns graceful default (undefined, [], no-op disposable, rejected Promise)
- Does NOT throw — extension continues running

### Extension.js throws during activate
- Catch error in shim, write to stdout: `{"type":"error","message":"activate() failed: ..."}`
- Swift shows error in UI
- Common cause: extension version mismatch, missing files

### stdin/stdout stream corruption
- Each line must be valid JSON (NDJSON)
- Invalid lines are logged and skipped
- Shim uses `readline` interface for line-by-line parsing

## Migration Path

1. **Phase 1:** Implement vscode-shim.js + ShimProcess.swift side by side with existing WebViewMessageHandler
2. **Phase 2:** Feature flag to switch between old (Swift) and new (shim) implementations
3. **Phase 3:** Validate all chat features work with shim
4. **Phase 4:** Remove WebViewMessageHandler.swift and ClaudeProcess.swift
5. **Phase 5:** Add SSH remote support (change Process spawn command)

## File Layout

```
Sources/Hangar/
  ShimProcess.swift          (NEW ~150 lines — replaces WebViewMessageHandler + ClaudeProcess)
  WebViewContainer.swift     (MODIFIED — connect to ShimProcess)
  ... (other files unchanged)

Resources/
  vscode-shim.js             (NEW ~800 lines — bundled in app)
```

## Dependencies

- **Node.js:** Required on user's machine. Not bundled. CC CLI users already have it.
- **No npm packages:** vscode-shim.js is self-contained, no node_modules needed.

## Success Criteria

1. All current Hangar chat features work (send message, streaming, tool use, permission prompts)
2. @file mention works (ripgrep-based file search via extension.js)
3. Session resume works
4. Extension updates require zero Hangar code changes (unless new vscode APIs are used)
5. WebViewMessageHandler.swift (1409 lines) is deleted
6. App binary size unchanged (no Node.js bundled)

## Future: SSH Remote

With stdio transport, SSH remote becomes a configuration change:

```swift
// Local
let process = Process()
process.executableURL = URL(fileURLWithPath: nodePath)
process.arguments = ["vscode-shim.js", "--extension-path", extPath, "--cwd", cwd]

// Remote
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
process.arguments = ["\(user)@\(host)", "node", "vscode-shim.js",
                     "--extension-path", remoteExtPath, "--cwd", remoteCwd]
```

Same NDJSON protocol over stdin/stdout. No code changes to ShimProcess or the webview layer.
