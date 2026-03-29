# Development Guide

Guide for developing and contributing to Hangar.

## Project Setup

### Prerequisites

- macOS 15.0+
- Xcode with macOS 15+ SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node.js >= 18 (for vscode-shim; `mise`, `nvm`, or `nodejs.org`)
- Claude Code VSCode extension installed (for webview assets)
- Claude CLI installed and authenticated

### Building

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build from command line
xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/Hangar.app
```

Or open `Hangar.xcodeproj` in Xcode, select the Hangar scheme, and run (Cmd+R).

### Project Configuration

The project is defined in `project.yml` (XcodeGen format):

- **Bundle ID:** `sh.saqoo.Hangar`
- **Deployment target:** macOS 15.0
- **Swift version:** 6.0
- **Concurrency:** Strict concurrency checking enabled (`SWIFT_STRICT_CONCURRENCY: complete`)
- **Resources:** `theme-light.css` is included as a bundle resource

## How to Update Theme CSS

The theme CSS file contains 456 CSS custom properties that replicate a VSCode color theme. To update or change the theme:

### 1. Export from VSCode

1. Open VSCode with the desired theme active (e.g., Default Light+, Default Dark+, or any custom theme)
2. Open the Command Palette (Cmd+Shift+P)
3. Run "Developer: Generate Color Theme From Current Settings"
4. This opens a JSON file with all color definitions

### 2. Convert to CSS

The exported JSON is a VSCode color theme file with a `colors` object mapping token names to hex colors. Convert it to CSS custom properties:

```javascript
// Example conversion (Node.js)
const fs = require('fs');

// Read and clean JSONC (strip comments)
let raw = fs.readFileSync('theme.json', 'utf8');
raw = raw.replace(/\/\/.*$/gm, '').replace(/,(\s*[}\]])/g, '$1');
const theme = JSON.parse(raw);

const lines = [':root {'];
for (const [key, value] of Object.entries(theme.colors).sort()) {
    const cssVar = `--vscode-${key.replace(/\./g, '-')}`;
    lines.push(`    ${cssVar}: ${value};`);
}
lines.push('}');

fs.writeFileSync('theme-light.css', lines.join('\n') + '\n');
```

### 3. Replace the File

Replace `Sources/Hangar/theme-light.css` with the new file. It is loaded at runtime from the app bundle by `VSCodeStub.themeCSSVariables`.

### Adding Dark Mode (Future)

To support dark mode:

1. Export a dark theme's CSS the same way (e.g., Default Dark+)
2. Save as `Sources/Hangar/theme-dark.css`
3. Add it as a bundle resource in `project.yml`
4. Modify `VSCodeStub.themeCSSVariables` to select the correct file based on `NSApp.effectiveAppearance`
5. Change `<body class="vscode-light">` to `<body class="vscode-dark">` when in dark mode
6. Listen for system appearance changes and reload the webview or swap CSS dynamically

## Debugging

### os_log (Unified Logging)

All Swift-side logging uses `os.log.Logger` with subsystem `sh.saqoo.Hangar`. Each source file has its own category:

| Category | Source |
|----------|--------|
| `AppState` | Screen transitions, session launch |
| `CCExtension` | Extension/CLI path discovery |
| `ClaudeProcess` | CLI process lifecycle, NDJSON parsing |
| `MessageHandler` | Protocol messages, auth, IO routing, history replay |
| `SessionHistory` | JSONL parsing, session listing |
| `VSCodeStub` | Theme CSS loading |
| `WebView` | WKWebView navigation events |

**View logs in Terminal:**

```bash
# Stream all Hangar logs
log stream --predicate 'subsystem == "sh.saqoo.Hangar"' --info

# Filter by category
log stream --predicate 'subsystem == "sh.saqoo.Hangar" AND category == "ClaudeProcess"' --info

# Search recent logs
log show --predicate 'subsystem == "sh.saqoo.Hangar"' --info --last 5m
```

The `--info` flag is required because `logger.info` messages are not shown by default.

Note: `print()` does not work when the app is launched via `open` command or Finder. Always use `Logger` for logging.

### Safari Web Inspector

The WKWebView has `isInspectable = true`, so you can debug the webview with Safari:

1. In Safari, enable "Show features for web developers" (Settings > Advanced)
2. Launch Hangar
3. In Safari menu: Develop > Hangar > _hangar.html
4. You get full Web Inspector: Elements, Console, Network, Sources, etc.

This is useful for:
- Inspecting the DOM structure and CSS
- Checking which `--vscode-*` variables are resolved
- Monitoring `window.postMessage` events in the console
- Profiling React rendering performance
- Debugging the CC extension's JavaScript

### Console Log Bridge

JavaScript `console.log`, `console.error`, and `console.warn` are bridged to Swift's unified logging system. You can see them in the Terminal log stream or in Xcode's console. Object arguments are serialized to JSON (truncated to 500 characters).

Uncaught errors and unhandled promise rejections are also captured.

### Inspecting CLI Communication

To see what is being sent to/from the Claude CLI:

```bash
# Watch CLI-related logs
log stream --predicate 'subsystem == "sh.saqoo.Hangar" AND category == "ClaudeProcess"' --info
```

This shows:
- CLI process start (PID, session ID)
- Parsed NDJSON event types
- System events (model name)
- Any stderr output from the CLI
- Process exit status

For stdin writes:

```bash
log stream --predicate 'subsystem == "sh.saqoo.Hangar" AND category == "ClaudeProcess" AND composedMessage CONTAINS "Writing to CLI stdin"' --info
```

## Key Design Decisions

### Why WKWebView Instead of Electron/Tauri

The CC extension already has a complete React UI designed for VSCode's webview panel. Rather than rebuilding the UI or wrapping it in Electron, Hangar loads it directly in a WKWebView with minimal stubs. This gives us:
- Native macOS app with minimal overhead
- The exact same UI as Claude Code in VSCode
- Automatic updates when the extension updates

### Why loadFileURL Instead of loadHTMLString

`WKWebView.loadHTMLString` does not grant access to local file resources. The CC extension's JavaScript imports modules and references assets via file paths, which fail under `loadHTMLString`. Writing an HTML file to disk and using `loadFileURL` with broad read access is the workaround.

### Why Home Directory Read Access

The `allowingReadAccessTo` parameter is set to the user's home directory because the webview needs to read from two separate locations:
- `~/Library/Application Support/Hangar/_hangar.html` (the entry point)
- `~/.vscode/extensions/anthropic.claude-code-*/webview/` (JS, CSS, assets)

A more restrictive path would not cover both locations.

### Why --include-partial-messages

Without this flag, the CLI only outputs batched `assistant` events (complete messages). With it, the CLI outputs `stream_event` lines containing real Anthropic SSE events (message_start, content_block_delta, etc.), enabling character-level streaming in the UI.

### Why Serial DispatchQueue in ClaudeProcess

The CLI's stdout can deliver data chunks on any thread via `readabilityHandler`. The line buffer (splitting raw data into NDJSON lines) is mutable state that must be accessed safely. A serial queue provides simple, correct synchronization without the complexity of actors (which would require async/await throughout).

### Why @unchecked Sendable

`ClaudeProcess` is marked `@unchecked Sendable` because Swift 6's strict concurrency checking requires `Sendable` conformance for objects shared across concurrency domains. The class manages thread safety manually via its serial `DispatchQueue` rather than using Swift's actor model, so the compiler cannot verify safety automatically.

### Content Array to String Conversion

The CC extension webview sends user messages with content as an array of typed blocks:
```json
{"content": [{"type": "text", "text": "Hello"}]}
```

The CLI's `stream-json` input format expects content as a plain string:
```json
{"content": "Hello"}
```

`WebViewMessageHandler.handleIOMessage` performs this conversion, extracting and joining text from content blocks.

## Common Issues and Solutions

### "Claude Code extension not found"

The app looks for `~/.vscode/extensions/anthropic.claude-code-*`. Make sure:
- VSCode is installed
- The Claude Code extension is installed in VSCode
- The extension directory exists (check with `ls ~/.vscode/extensions/ | grep claude`)

### "Claude CLI not found"

The app checks these paths in order:
1. `~/.local/bin/claude`
2. `/usr/local/bin/claude`
3. `/opt/homebrew/bin/claude`

Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`

### Auth shows unauthenticated

Run `claude auth login` in Terminal first. Hangar reads auth status by running `claude auth status` as a subprocess.

### Webview is blank or shows errors

1. Open Safari Web Inspector (Develop > Hangar) to check for JS errors
2. Check os_log: `log stream --predicate 'subsystem == "sh.saqoo.Hangar"' --info`
3. Verify the extension's webview files exist: `ls ~/.vscode/extensions/anthropic.claude-code-*/webview/`

### Theme looks wrong

If CSS variables are missing or incorrect:
1. Inspect in Safari Web Inspector, check computed styles for `--vscode-*` variables
2. The theme CSS may need updating after a VSCode/extension update
3. Re-export from VSCode (see "How to Update Theme CSS" above)

### CLI process hangs or doesn't respond

Check stderr output: `log stream --predicate 'composedMessage CONTAINS "[CLI stderr]"' --info`

The CLI may be waiting for authentication or hitting rate limits. Check `log stream` output for `rate_limit_event` messages.

### Build fails after extension update

If the CC extension updates its webview protocol (new message types, changed response formats), the `WebViewMessageHandler` may need updates. Check Safari Web Inspector console for unhandled request types, which are logged as warnings.

**With vscode-shim:** Extension updates should require zero code changes. The shim runs extension.js directly. If a new vscode API is used, the Proxy will log warnings to stderr — check with:
```bash
node --test --test-timeout 120000 test/shim-integration.test.js
```

## VSCode Shim Development

### Architecture

The vscode-shim (`Resources/vscode-shim/`) runs the CC extension's `extension.js` in a Node.js subprocess. It intercepts `require("vscode")` and provides a compatibility shim that bridges the extension's webview I/O to Hangar's WKWebView via stdin/stdout NDJSON.

See `docs/superpowers/specs/2026-03-29-vscode-shim-design.md` for the full design spec.

### Running the shim standalone

```bash
# Run shim directly (for debugging)
node Resources/vscode-shim/index.js \
  --extension-path ~/.vscode/extensions/anthropic.claude-code-* \
  --cwd /tmp

# Sends {"type":"ready"} to stdout when initialized
# Reads NDJSON from stdin, writes NDJSON to stdout
# Extension logs go to stderr
```

### Running tests

```bash
# Unit tests — fast, no external deps
node --test test/shim-unit.test.js

# Integration tests — spawns real extension.js, needs CC extension installed
node --test --test-timeout 120000 test/shim-integration.test.js
```

### Shim module structure

| Module | Responsibility |
|--------|---------------|
| `index.js` | Entry: console redirect, Module hook, activate, stdin routing |
| `protocol.js` | NDJSON stdin reader + stdout writer |
| `types.js` | Uri, EventEmitter, Disposable, enums (all vscode types) |
| `context.js` | ExtensionContext with JSON-backed globalState |
| `commands.js` | registerCommand / executeCommand / setContext |
| `workspace.js` | getConfiguration (3-layer), workspaceFolders, findFiles |
| `window.js` | Webview bridge (postMessage ↔ stdio), Tier 2 stubs |
| `notifications.js` | show*Message with 60s timeout + response routing |
| `env.js` | appName, machineId, clipboard, openExternal |
| `stubs.js` | Proxy-based unknown API detection, module assembly |

### Debugging the shim

```bash
# Watch shim stderr (extension logs, warnings, errors)
node Resources/vscode-shim/index.js --extension-path ... --cwd /tmp 2>&1 >/dev/null

# Send test messages via stdin
echo '{"type":"webview_message","message":{"type":"request","requestId":"1","request":{"type":"init"}}}' \
  | node Resources/vscode-shim/index.js --extension-path ... --cwd /tmp
```

### Adding support for new vscode APIs

When the CC extension starts using a new vscode API, the Proxy will log:
```
[vscode-shim] WARN: Unknown vscode API accessed: vscode.newApi
```

To add support:
1. Check extension.js to understand how the API is used
2. Add implementation to the appropriate module (window.js, workspace.js, etc.)
3. Add unit test to `test/shim-unit.test.js`
4. Run integration tests to verify
