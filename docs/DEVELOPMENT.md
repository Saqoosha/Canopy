# Development Guide

Guide for developing and contributing to Canopy.

## Project Setup

### Prerequisites

- macOS 15.0+
- Xcode 26 toolchain (Xcode 16.4 fails with actor-isolation errors; `SWIFT_VERSION: "6.0"` is the language mode, not the compiler)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node.js >= 18 (for vscode-shim; `mise`, `nvm`, or `nodejs.org`)
- Claude Code VSCode extension, either installed in VSCode or in Canopy's own folder (see "Claude Code extension not found" below)
- Claude CLI installed and authenticated

### Building

```bash
# Debug build signed with an Apple Development identity, so TCC grants persist across rebuilds
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```

Without that signing identity, use plain `xcodebuild`:

```bash
xcodegen generate
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build
```

Do not use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) for interactive development: it re-triggers the TCC prompts on every launch.

`project.yml` is the source of truth and `Canopy.xcodeproj` is gitignored. Run `xcodegen generate` after editing `project.yml`; an Xcode GUI build does not regenerate it.

### Debug beside Release

The Debug build has its own bundle id, so it runs next to the installed app with its own daemon, socket and LaunchAgent. Two things are shared between the builds:

- `~/Library/Application Support/Canopy/`, including `settings.json`
- the `Logger` subsystem `sh.saqoo.Canopy`

### Project Configuration

The project is defined in `project.yml` (XcodeGen format):

- **Bundle ID:** `sh.saqoo.Canopy` (Release) / `sh.saqoo.Canopy.debug` (Debug — pinned in the `Debug:` config, so it applies to every build route once the project is regenerated; an Xcode GUI build uses the last generated `Canopy.xcodeproj`, which is gitignored)
- **Deployment target:** macOS 15.0
- **Swift version:** 6.0
- **Concurrency:** Swift 6 language mode (`SWIFT_VERSION: 6.0`) is what enforces actor isolation. `project.yml` also lists `SWIFT_STRICT_CONCURRENCY: complete`, but that key is a sibling of `configs:` and XcodeGen discards it, so it has never applied — see issue #143
- **Resources:** `theme-light.css` and `Resources/vscode-shim/` (folder reference) are included as bundle resources

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

Replace `Sources/Canopy/theme-light.css` with the new file. It is loaded at runtime from the app bundle by `VSCodeStub.themeCSSVariables`.

### Adding Dark Mode (Future)

To support dark mode:

1. Export a dark theme's CSS the same way (e.g., Default Dark+)
2. Save as `Sources/Canopy/theme-dark.css`
3. Add it as a bundle resource in `project.yml`
4. Modify `VSCodeStub.themeCSSVariables` to select the correct file based on `NSApp.effectiveAppearance`
5. Change `<body class="vscode-light">` to `<body class="vscode-dark">` when in dark mode
6. Listen for system appearance changes and reload the webview or swap CSS dynamically

## Debugging

### os_log (Unified Logging)

All Swift-side logging uses `os.log.Logger` with subsystem `sh.saqoo.Canopy`. Most source files have their own category, named after the file; `grep -rhn 'category:' Sources/Canopy` lists them. The ones reached for most often:

| Category | Source |
|----------|--------|
| `ShimProcess` | Node.js subprocess, NDJSON bridge, trackers |
| `CanopyDaemon`, `DaemonSupervisor`, `DaemonRegistration` | Daemon start, registration, supervision |
| `ControlSession`, `ControlClient`, `ControlEvents` | Control connections and the event log |
| `MirrorServer`, `MirrorPane`, `MirrorRelay` | Session connections, attached panes, the update relay |
| `SessionStore`, `SessionReaper` | Session registry, idle stops |
| `SleepGuard` | Sleep assertions and lid-close handling |
| `ExtensionUpdater`, `CCExtension` | Extension download, canary, path discovery |
| `SessionHistory` | JSONL parsing, session listing |
| `WebView` | WKWebView navigation events |

**View logs in Terminal:**

```bash
# Stream all Canopy logs
/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy"' --info

# Filter by category
/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "ShimProcess"' --info

# Search recent logs
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy"' --info --last 5m
```

- Call `/usr/bin/log`: a bare `log` can hit a shell builtin.
- The `--info` flag is required because `logger.info` messages are not shown by default. `info` is a short ring buffer, so anything read later must be logged at `notice`.
- `debug` is never stored. `log show --debug` returns nothing; use `log stream --level debug`.
- The GUI, the daemon, Debug and Release all log as process `Canopy` under one subsystem. Filter one process with `Canopy[<pid>`.
- String interpolations show as `<private>` unless marked `privacy: .public`.

Note: `print()` does not work when the app is launched via `open` command or Finder. Always use `Logger` for logging.

### Safari Web Inspector

The WKWebView has `isInspectable = true`, so you can debug the webview with Safari:

1. In Safari, enable "Show features for web developers" (Settings > Advanced)
2. Launch Canopy
3. In Safari menu: Develop > Canopy > `_canopy-<session-id>.html` (one entry per open session)
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

### Inspecting Shim Communication

```bash
# Watch shim subprocess logs (Node.js stderr + message routing)
/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "ShimProcess"' --info

# Watch Node.js discovery
/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "NodeDiscovery"' --info
```

### Daemon

This Mac's sessions run in the daemon, so most session logs come from the daemon process, not the GUI.

- A Release GUI registers the LaunchAgent on every launch. A Debug GUI registers its own agent only with `CANOPY_REGISTER_DAEMON=1`; otherwise it starts `Canopy --daemon` itself as a child process.
- The Debug socket is `~/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock`. Point the control client at it with `scripts/canopyctl --socket <path> ...`; the default is the Release socket.
- The Mirror TCP port exists only while Mirror is on, and Debug uses the base port + 1.
- The logic probe (`CANOPY_RUN_LOGIC_PROBE=1`) runs sessions in-process, without a daemon.

See `docs/CONTROL_PROTOCOL.md` for the wire and `docs/notes/source-files.md` for daemon hazards.

### Debug Auto-Launch (currently inert)

This was meant to skip the launcher and start a session automatically. **It does
nothing today.** `AppState` reads `debugAutoLaunchDir` into a property and nothing
consumes it — `grep -rn debugAutoLaunch Sources/` returns the declaration and that one
read — so no route skips the launcher, and nothing clears the key either.

```bash
defaults write sh.saqoo.Canopy.debug debugAutoLaunchDir /path/to/dir
open build/Build/Products/Debug/Canopy.app
```

The domain is recorded for whenever a consumer is restored: it is
`sh.saqoo.Canopy.debug`, not `sh.saqoo.Canopy`, because `AppState.init()` reads
`UserDefaults.standard`, which follows the bundle ID, and Debug's is pinned separately
in `project.yml`.

## Key Design Decisions

### Why WKWebView Instead of Electron/Tauri

The CC extension already has a complete React UI designed for VSCode's webview panel. Rather than rebuilding the UI or wrapping it in Electron, Canopy loads it directly in a WKWebView with minimal stubs. This gives us:
- Native macOS app with minimal overhead
- The exact same UI as Claude Code in VSCode
- Automatic updates when the extension updates

### Why loadFileURL Instead of loadHTMLString

`WKWebView.loadHTMLString` does not grant access to local file resources. The CC extension's JavaScript imports modules and references assets via file paths, which fail under `loadHTMLString`. Writing an HTML file to disk and using `loadFileURL` with broad read access is the workaround.

### Why Home Directory Read Access

The `allowingReadAccessTo` parameter is set to the user's home directory because the webview needs to read from two separate locations:
- `~/Library/Application Support/Canopy/_canopy-<session-id>.html` (the per-session entry point)
- `~/.vscode/extensions/anthropic.claude-code-*/webview/` (JS, CSS, assets)

A more restrictive path would not cover both locations.

### Why --include-partial-messages

Without this flag, the CLI only outputs batched `assistant` events (complete messages). With it, the CLI outputs `stream_event` lines containing real Anthropic SSE events (message_start, content_block_delta, etc.), enabling character-level streaming in the UI.

### Why @unchecked Sendable

`ShimProcess` is marked `@unchecked Sendable` because Swift 6's strict concurrency checking requires `Sendable` conformance for objects shared across concurrency domains. The class manages thread safety manually via serial queues and main-thread-only access patterns rather than using Swift's actor model.

## Common Issues and Solutions

### "Claude Code extension not found"

The app looks for `anthropic.claude-code-*` in two places and uses the newest:
- `~/Library/Application Support/Canopy/extensions/` (Canopy's own copies; `ExtensionUpdater` installs updates here)
- `~/.vscode/extensions/`

Check with `ls ~/Library/Application\ Support/Canopy/extensions ~/.vscode/extensions | grep claude`.

### "Claude CLI not found"

The app checks these paths in order:
1. `~/.local/bin/claude`
2. `/usr/local/bin/claude`
3. `/opt/homebrew/bin/claude`

Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`

### Auth shows unauthenticated

Run `claude auth login` in Terminal first. Canopy reads the CLI's OAuth item from the login Keychain (`KeychainAuth`); an item without `scopes` is treated as logged out. A session on an additional account reads the item for that account's `CLAUDE_CONFIG_DIR`.

### Webview is blank or shows errors

1. Open Safari Web Inspector (Develop > Canopy) to check for JS errors
2. Check os_log: `/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy"' --info`
3. Verify the extension's webview files exist: `ls <extension folder>/webview/`

### Theme looks wrong

If CSS variables are missing or incorrect:
1. Inspect in Safari Web Inspector, check computed styles for `--vscode-*` variables
2. The theme CSS may need updating after a VSCode/extension update
3. Re-export from VSCode (see "How to Update Theme CSS" above)

### CLI process hangs or doesn't respond

Check shim stderr output: `/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "ShimProcess"' --info`

The CLI may be waiting for authentication or hitting rate limits.

### Build fails after extension update

Extension updates should require zero code changes. The shim runs extension.js directly. If a new vscode API is used, the Proxy will log warnings to stderr — check with:
```bash
node --test --test-timeout 120000 test/shim-integration.test.js
```

## VSCode Shim Development

### Architecture

The vscode-shim (`Resources/vscode-shim/`) runs the CC extension's `extension.js` in a Node.js subprocess. It intercepts `require("vscode")` and provides a compatibility shim that bridges the extension's webview I/O to Canopy's WKWebView via stdin/stdout NDJSON.

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
# Unit tests — fast, no external deps; the list CI runs
node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)

# Integration tests — spawns real extension.js, needs CC extension installed
node --test --test-timeout 120000 test/shim-integration.test.js

# Swift logic probe, ~3 s
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Every file under `test/` must appear in one of `CI_TEST_FILES`, `EXCLUDED_TEST_FILES` or `NON_TEST_FILES` in `.github/workflows/ci.yml`, and CI asserts count floors. See `docs/notes/testing.md`.

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
| `cjk-emphasis.js`, `cjk-emphasis-stream.js` | Repair of CJK bold markup in the outgoing stream |
| `keychain-login-guard.js` | Reports a damaged Keychain login as logged out |

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
