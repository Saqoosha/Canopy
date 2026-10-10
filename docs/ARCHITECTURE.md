# Architecture

Canopy runs the Claude Code VSCode extension without VSCode. Two ideas carry the design:

1. **Canopy does not reimplement Claude Code's protocol.** The extension's `extension.js` is loaded unmodified in a Node.js subprocess, with only the `vscode` module replaced by a shim. The UI is the extension's own React webview, shown in a `WKWebView`.
2. **The process that owns a session is not the window that shows it.** Since 3.0 every session on a Mac lives in a background daemon, `canopyd`. The Mac app, another Mac, the phone and a script are all clients that attach to it.

This document describes Canopy 3.14. A walkthrough with diagrams (in Japanese) is at `docs/architecture.html`. The script-facing wire is in `docs/CONTROL_PROTOCOL.md`. Hazards and measured numbers live in `docs/notes/` and on the code's doc comments; this file links to symbols rather than restating them.

## System Overview

```
Canopy.app (this Mac)   Canopy.app (another Mac)   Canopy Mobile   canopyctl / scripts
     │ Unix socket            │ TCP · Tailscale        │ TCP · Tailscale   │ Unix socket
     └────────────────┬───────┴────────────────────────┴───────────────────┘
                      ▼
canopyd   (Canopy.app/Contents/MacOS/Canopy --daemon · one LaunchAgent per Mac · no NSApplication)
  ├─ ControlSession    control connections: list, open, stop, send_message, listen, …
  ├─ MirrorServer      session connections: attach, transcript replay, assets, file transfer
  ├─ SessionStore      session registry: open sessions, Recents, titles, accounts, rate limits
  ├─ coordinators      keep-alive, recap, title generation, reaper, upgrade check, sleep guard
  ├─ RosterPublisher ──► Cloudflare relay (machine list, roster, phone events, push)
  └─ ShimProcess × N   one per running session; fans output out to every attached client
        │ stdin / stdout NDJSON
        ▼
     node vscode-shim      fakes require("vscode"): webview, workspace, secrets
        └─ extension.js    the Claude Code extension, as shipped
             └─ claude     CLI in stream-json mode (through a wrapper for SSH remote)
```

The relay carries the machine list, the roster of open sessions, the phone's events (including message text) and notifications. The webview stream and transcript replays never pass through it: they flow directly between a client and the daemon, over the Unix socket or Tailscale.

## Processes

One binary plays several roles. `CanopyMain` reads the arguments before anything touches `NSApplication`:

| Arguments | Role |
|---|---|
| none | The SwiftUI app (`CanopyApp`) |
| `--daemon` | `CanopyDaemon.run()`: the session service |
| `--mirror-relay <host> <port> <socket>` | `MirrorRelay`: holds the Tailscale port for a daemon that is waiting to restart |
| `--unregister-daemon` | Removes the LaunchAgent and exits |

**GUI (`Canopy.app`).** Sidebar, up to 6 panes, launcher, settings, MacroPad. It holds no shim for this Mac's sessions. A pane whose `OpenSession.isDaemonHosted` is true is a `MirrorPaneView` that attaches to the daemon, the same view and the same route as a pane showing another Mac's session.

**Daemon (`canopyd`).** Started by launchd as a LaunchAgent, so it runs inside the login session and can read the CLI's OAuth token from the login keychain. It builds no `NSApplication` and runs on `RunLoop.main`, so LaunchServices does not see a second instance of the app. It has the app's code identity, so a Full Disk Access grant covers both.

**Node (`vscode-shim`).** `Resources/vscode-shim/index.js` intercepts `require("vscode")` and activates `extension.js`. Unimplemented API members go through a Proxy that logs the access, so a new extension API fails loudly.

**CLI (`claude`).** Spawned by the extension with `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`. Canopy never passes `--bare`.

**SSH remote is the exception.** Its `ShimProcess` stays in the GUI (`isDaemonHosted` is false for `.remote`), and the extension's `claudeProcessWrapper` points at `ssh-claude-wrapper.sh`, which runs `claude` on the host.

## Message Flow

What happens when Return is pressed in a pane on this Mac. A pane on another Mac or the phone takes the same path; only the Unix socket becomes TCP over Tailscale.

Prompt, outbound:

1. **WKWebView.** The extension's React UI calls `acquireVsCodeApi().postMessage`. Canopy's stub (`VSCodeStub`) turns that into a post to `webkit.messageHandlers.vscodeHost`.
2. **GUI, `RemoteMirrorBridge`.** Sends the message as one NDJSON line on the pane's session connection.
3. **`MirrorServer`.** The connection is already attached to one session; the line goes to that session's `ShimProcess`.
4. **`ShimProcess` → node.** Written to the shim's stdin. `window.js` delivers it to the extension as a webview message.
5. **`extension.js` → CLI.** The extension writes a stream-json user turn to the CLI's stdin.

Reply, inbound:

1. **CLI.** Emits Anthropic SSE events as `stream_event` lines, then `assistant` and `result`.
2. **`extension.js`.** Wraps each one in `io_message` and posts it to its webview.
3. **node shim.** Writes it to stdout. The repair of CJK bold markup (`cjk-emphasis*.js`) happens here, before the line leaves Node.
4. **`ShimProcess`.** Reads the line once for its own trackers (status bar, activity state, background tasks, rate limits, control events) and sends it to every attached client.
5. **WKWebView.** The extension's UI renders its own message. The CJK repair is the only transformation on the way.

A session with no pane still works. For a session opened by the control API or the phone, the daemon synthesizes `init` and `launch_claude` on the channel `canopy-headless`, so a turn runs without a webview and a later attach finds a cached init.

## Connections

A client opens two kinds of connection to a daemon. Both are newline-delimited JSON.

| Connection | Count | First line | Carries |
|---|---|---|---|
| control | One per client per daemon | `hello {protocolVersion, token?}` | Requests with an id, one `response` each. After `subscribe`: `session_state` and `upgrade_state` pushes |
| session | One per attached pane | `attach` | The webview's own NDJSON in both directions, the transcript replay at attach, webview assets on request, file transfer, and server-to-client instructions (`canopy_ui`, `open_url`, `notify`) |

- **Socket.** `~/Library/Application Support/Canopy/daemon-<bundle id>.sock`, mode 0600. The bundle id keeps a Debug daemon from taking the Release socket. A path over 103 bytes falls back to the per-user temporary directory (`DaemonPaths`).
- **Authentication.** The local socket is protected by file mode and takes no token. The TCP listener needs the Mirror password token and exists only while Mirror is on in Settings › Sharing. Debug listens on the base port + 1.
- **Version.** `ControlProtocol.version` is 1. A mismatch gets `hello_error` with a reason and the socket closes.
- **Attach capabilities.** A client opts into extras with flags on the `attach` line, among them `status`, `usage`, `images`, `ui`, `files`, `restart`, `compress: "br"` (lines of 4 KB or more become Brotli `Z <n> <m>` frames). Every option is opt-in, so older clients are unaffected. `usage`, `images`, `ui` and `files` are honored for Mac clients only.
- **Attach resume.** `ShimProcess` keeps recent outbound frames in a `MirrorFrameRing`. A phone that iOS disconnected re-attaches with `since: {epoch, seq}` and receives only what it missed; a cursor older than the ring's floor falls back to a full replay.
- **UI frames.** The daemon has no pane, so it asks its Mac client to show things with `canopy_ui` frames (`MirrorUIFrame`): file contents in `ContentViewer`, the recap row, an error banner, an alert, a notification. The frames are data only; the client builds any JavaScript itself.

### Control verbs

The verbs a client uses; GUI-internal ones are left out.

| Group | Verbs |
|---|---|
| Sessions | `list_sessions` (`scope: open` or `recent`, with search filters), `open_session` (new, or `resumeSessionId` to continue a closed one), `stop_session`, `rename_session`, `restart_session`, `request_recap` |
| Driving a session | `send_message`, `wait_turn`, `latest_reply`, `session_status`, `pending_requests`, `history`, `listen` |
| Folders | `list_folders`, `browse_dir`, `mkdir` |
| Accounts | `list_accounts`, `switch_account` |
| Daemon | `subscribe`, `mirror_status`, `restart_now` (local clients only) |

`docs/CONTROL_PROTOCOL.md` is the reference for parameters, results and error codes.

## Control API

The control connection is also a local automation API: a script, or another agent, can start a session, send it turns and wait for what happens, with no pane open. `scripts/canopyctl` is a stdlib-only Python client.

- **Events.** The daemon records `turn_done`, `permission`, `asking`, `turn_interrupted`, `session_opened` and `session_closed` in an event log (`ControlEventLog`, in `ControlEvents.swift`) whether or not anyone listens. A `listen` can also filter for replies addressed to a name (`addressed`). `listen` waits for the next event after a cursor, so a client that reconnects with its cursor misses nothing. A cursor that cannot be continued returns `gap`.
- **History.** `history` reads turns back from the session's transcript (`ControlHistory`), so turns typed in a pane or on the phone are included.
- **Permissions.** `session_status` reports a pending permission with the raw tool input, and `pending_requests` lists what a session is waiting on.
- **Across a restart.** A daemon that exits cleanly saves its event log and the next one continues it with the same epoch and seqs. Sessions that the control API or the phone opened may have no client to re-attach them, so `DaemonHeldSessions` carries them across a restart under the same `key`.
- **Reaper.** A session `open_session` started is kept alive while a `listen` covers it. The daemon sends a `heartbeat` every 30 s on a connection with an open `listen`.

## Session Lifecycle

Closing a pane and stopping a session are different operations.

| State | Meaning |
|---|---|
| Running, attached | The shim runs and at least one client is watching. Keep-alive warms the prompt cache only for sessions in this state |
| Running, detached | Cmd+W closes the pane, not the session. It keeps running in the daemon and stays in every client's Open list |
| Stopped | By Stop Session (Cmd+Opt+W, or the menu beside the pane's X), or by the reaper |
| Daemon restart | Clients re-attach and sessions resume from their transcripts |

- **Attach doubles as resume.** An `attach` with `open` for a session the daemon is not running resumes it on the spot. Opening an old session, returning to a stopped one and restoring panes after a relaunch all use this one path, so Save and Quit carries no shim state.
- **Reaper.** `SessionReaper` stops a session that has no client, is not working or asking, and has no pending permission or background task, once that has lasted for Settings › General › "Stop idle sessions after" (4 hours by default; Never turns it off). Two kinds of session are held open without a client (`ShimProcess.reaperHolds`): one the phone opened, until Stop, and one the control API opened, while a `listen` covers it. A reaped session keeps its Open row and resumes on click; one stopped with Stop Session returns to Recents.
- **Stopped elsewhere.** When a session is stopped from another client, the daemon tells the remaining clients it ended rather than dropping their connections, and the pane says where it was stopped.
- **Removed folders.** A session whose working directory or worktree was deleted can still be reopened, and it holds a daemon upgrade because it could not be resumed afterwards.

## State Ownership

| State | Owner | Notes |
|---|---|---|
| Running sessions, shims, activity state | Daemon | `SessionStore.openSessions` inside canopyd |
| Recents, folders, titles | Daemon, per Mac | Clients ask with `list_sessions` / `list_folders`. Never on the relay |
| Settings that affect a session | Daemon | Default permission mode, keep-alive, recap, worktree seeding, accounts, model providers. Read from the shared `settings.json` |
| Rate limits | Daemon | Collected per account and pushed to clients |
| Event log for `listen` | Daemon | Saved on a clean exit |
| Pane order and widths, window, filters, MacroPad | Client | Each Mac's GUI keeps its own layout |
| Machine list, presence, roster of open sessions | Relay | Phone events and notification bodies also pass through it |

## Daemon Operations

### Registration and start

- A Release GUI checks the LaunchAgent (`SMAppService.agent`, plist inside the bundle) on every launch and registers it if missing. Debug registers only with `CANOPY_REGISTER_DAEMON=1`. Each build owns its own agent, keyed by bundle id.
- Before a pane attaches, `DaemonSupervisor` checks the socket. If the agent is registered but silent, it runs `launchctl kickstart` and waits for the socket. If the agent is unregistered or awaiting approval, or launchd could not start it, the GUI starts `--daemon` itself as a plain `Process`, never through `NSWorkspace.openApplication`.

### App updates

- Sparkle replaces the app. The daemon notices the new build on disk and counts what holds a restart back (`DaemonUpgrade`, `ShimProcess.upgradeBlocker`). That includes a running turn, a question waiting for an answer, a background task, an unsent prompt, an in-flight keep-alive or recap, a waiting phone reply, a session whose folder was removed, and a client that cannot re-attach on its own.
- While it waits, `Canopy --mirror-relay`, started from the new build, holds the Tailscale port and copies bytes to the daemon's relay socket. macOS's Application Firewall cannot resolve the path of the replaced daemon and drops all its inbound traffic. The relay socket requires the password like TCP does.
- When nothing holds it, the daemon sends `daemon_restarting`, stops its shims and exits 1; launchd starts the new build. Mirror panes on other Macs wait for the listener and re-attach (`RestartReattach`).
- The sidebar footer shows the waiting update with marketing versions, the sessions holding it, and Restart now (`PendingUpdate`).

### Claude Code extension updates

- Canopy keeps its own copies of the extension under `~/Library/Application Support/Canopy/extensions/` and also finds `~/.vscode/extensions/anthropic.claude-code-*` (`CCExtension`). The newest one wins.
- `ExtensionUpdater` asks the VS Marketplace for the latest version and installs it without a prompt. Before adopting a download, `ExtensionCanary` activates it in a throwaway shim; a version that throws during `activate` is not adopted. Versions still in use by a running session are kept on disk.
- Running sessions stay on the extension they started with. The sidebar footer lists sessions on an older extension and one Restart All moves them.

### Sleep

- `SleepGuard` holds an idle-sleep assertion while a session is busy (Settings › General › "Prevent sleep while a session is working"). With "Stay reachable remotely" it also holds while any session is open, so the phone and other Macs can still reach the Mac.
- The daemon's guard additionally disables lid-close sleep, which the assertion alone does not prevent. `SleepGuardPolicy` decides when re-enabling it is harmless.
- On battery below `sleepBatteryFloorPercent` the Mac is allowed to sleep whatever is running. While a lid-closed Mac is held awake on battery, the phone gets battery notifications.
- The sidebar footer's cup shows whether Canopy is holding the Mac awake (`AwakeStatus`, read from the system's assertion list) and toggles the setting on click.

## Accounts and Usage

- A second Claude login is a `ClaudeAccount`: a name plus a `CLAUDE_CONFIG_DIR`. The CLI keys its Keychain item by that path, so each directory holds its own login. `ClaudeConfigDirSync` links every top-level entry of the base config dir into the account's dir (`projects`, `CLAUDE.md`, rules, hooks, skills) except `.claude.json` and `backups`, and copies the user-scope `mcpServers`. Accounts therefore share everything but the login, and a session can be resumed under another account.
- A session can be switched between accounts (`switch_account`). When a session hits its limit, `AccountLimitBanner` offers the other logins, and a new session starts on a login with quota left.
- Rate limits are tracked per account (`SharedRateLimitData`). `ClaudeUsageDirect` reads `/api/oauth/usage` so the sidebar bars exist before any session runs. Bars are colored by pace when the reset time is known, and by percent otherwise; an exhausted quota is always red.
- The context meter's denominator comes from the CLI itself: Canopy loads one Claude Code mod, `Resources/canopy-bridge/`, through `CLAUDE_CODE_PLUGIN_DIRS`. It reports the context window, and the worktree the session is in, as `system/ui_log` frames that `ShimProcess` consumes before anything else sees them.
- Custom model providers (`ModelProvider`) point a session at any Anthropic-compatible endpoint, with per-tier model mapping.

## Mac Client

- `SessionStore` is also the GUI's model: open rows, Recents, panes, the focused pane. Each pane is a `PaneSlot` whose width is a weight. `WeightedPaneLayout`, a custom SwiftUI `Layout`, divides the detail column by weight and returns the proposed width unchanged.
- The sidebar's Open block is a map of the pane order: reading the highlighted rows top to bottom gives the panes left to right. Worktree sessions are grouped under their repository, and the sidebar has session search.
- The sidebar dot and the MacroPad LED both read one classification, `SessionActivity`.
- `DaemonSessionSync` reconciles the GUI's rows with the daemon's `session_state` pushes.
- Each pane's webview loads a per-session entry file and receives Canopy's injected scripts: the `acquireVsCodeApi` stub, theme CSS, image previews, scroll preservation, composer focus, the recap row.
- `GPUProcessReaper` kills WebKit GPU processes that WebKit has abandoned, which otherwise leave a page that never paints again.
- The launcher takes a first prompt with dropped or pasted images (`LaunchPrompt`), can clone from GitHub, and can start the session in a new worktree.

## Other Routes

**Another Mac's daemon.** The sidebar lists other Macs' sessions from the relay. Opening one attaches a `.mirror` pane to that Mac's canopyd over Tailscale; the transcript, files and CLI stay on that Mac. From the launcher this Mac can also start a new prompted session there, browse any folder on it (`RemoteDirectoryBrowser`, `browse_dir` / `mkdir`), open its closed sessions and recent folders (`MirrorRecents`), and stop its sessions (`PeerControl`). A file clicked in a mirror pane is shipped over the mirror connection and opened on the watching Mac (`MirrorFileTransfer.swift`), an `open` the CLI runs is redirected to the watching machine (`OpenRedirect`), and an MCP OAuth page opens on the Mac that asked.

**Canopy Mobile.** Finds Macs through the relay and speaks the same control and session protocol over Tailscale. Notifications arrive as relay pushes with the session's name, and a reply (free text or an AskUserQuestion option) becomes a real user turn. Sessions the phone opened keep running without a pane and are resumed after an upgrade restart.

**SSH remote.** For hosts that cannot run the daemon: Linux, WSL, Windows. The shim runs on this Mac and the wrapper runs `claude` on the host. See `docs/notes/ssh-remote.md`.

**Claude Code on the Web.** Cloud sessions are listed from `/v1/sessions` with the Keychain OAuth token and teleported into a local session through a short-lived shim (`RemoteSessionsBridge`).

**MacroPad.** An optional USB key pad, driven over serial or over TCP from another Mac. Firmware: <https://github.com/Saqoosha/Canopy-MacroPad>.

## Source Map

Under `Sources/Canopy/` unless noted. Open the file and read its doc comments for detail.

| Area | Files |
|---|---|
| Entry and daemon | `CanopyMain`, `CanopyDaemon`, `DaemonSupervisor`, `DaemonRegistration`, `DaemonPaths`, `DaemonConfig`, `DaemonUpgrade`, `DaemonUpgradeCenter`, `DaemonHeldSessions`, `MirrorRelay`, `SessionReaper`, `DaemonReaper`, `SleepGuard` |
| Control protocol | `ControlProtocol`, `ControlSession`, `ControlClient`, `ControlEvents`, `ControlHistory`, `PeerControl`, `scripts/canopyctl` |
| Session connections | `MirrorServer`, `MirrorClient`, `MirrorWire`, `MirrorSink`, `MirrorAccess`, `MirrorEndpoint`, `MirrorFrameRing`, `MirrorStatusFrame`, `MirrorUIFrame`, `MirrorFileTransfer`, `MirrorRecents`, `RestartReattach`, `NDJSONLineAssembler` |
| Sessions | `ShimProcess`, `SessionStore`, `OpenSession`, `DaemonSessionSync`, `SessionActivity`, `KeepAlive*`, `Recap*`, `SessionTitle*`, `ClaudeSessionHistory`, `SubagentTracker`, `GitWorktree`, `PeerNameStore` |
| Accounts and usage | `ClaudeAccount`, `ClaudeAccountInfo`, `KeychainAuth`, `SharedRateLimitData`, `ClaudeUsageDirect`, `AnthropicDirect`, `AccountLimitBanner`, `ModelProvider*` |
| Extension | `CCExtension`, `ExtensionUpdater`, `ExtensionSafety`, `NodeDiscovery` |
| Mac client UI | `CanopyApp`, `Sidebar*`, `Detail`, `SessionContainer`, `MirrorPaneView`, `WebViewContainer`, `WeightedPaneLayout`, `PaneSlot`, `PaneDivider`, `PaneHeader*`, `LauncherView`, `StatusBarView`, `SettingsView`, `PendingUpdate`, `AwakeIndicator`, `GPUProcessReaper`, `MacroPad/` |
| Relay and phone | `Roster/RosterPublisher`, `Roster/RemoteRosterWatcher`, `Roster/RosterNotifier`, `Roster/RosterReply`, `Roster/SessionEvent`, `PhoneReplyQueue` |
| Node side | `Resources/vscode-shim/` (`index.js` entry, `window.js` webview bridge, `workspace.js`, `context.js`, `cjk-emphasis*.js`, `keychain-login-guard.js`), `Resources/canopy-bridge/`, `Resources/ssh-claude-wrapper.sh`, `Resources/canopy-remote-open.sh` |

Design records: `docs/superpowers/specs/2026-09-29-canopy-server-design.md`, `2026-10-01-headless-daemon-design.md`, `2026-10-01-update-without-waiting-design.md`, `2026-10-02-canopy-bridge-mod-design.md`.

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

The extension's own stylesheet, linked from its install directory (`<extension folder>/webview/index.css`). Loaded unmodified via `<link>` tag — no Canopy changes.

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

## WebView Setup

### Entry file

`WKWebView.loadHTMLString` cannot load local file resources, and the extension's `index.js` imports modules and assets by file path. So `WebViewContainer.loadCCWebview` writes an HTML file and loads it with `loadFileURL`, granting read access to a parent directory that covers both the entry file and the extension folder.

There is one entry file per session, `~/Library/Application Support/Canopy/_canopy-<OpenSession.id>.html`, never shared: `data-initial-session` is baked in and loads are asynchronous, so a shared file would render the wrong conversation. The file must outlive the load because `reload()` re-reads it. `purgeOwnEntryFiles()` deletes only this process's files, at quit, because Debug and Release share the directory.

### Script message handlers

| Handler | Purpose |
|---|---|
| `vscodeHost` | The extension's `postMessage`, routed to the shim (in-process pane) or the session connection (attached pane) |
| `consoleLog` | JS console output, uncaught errors and unhandled rejections → unified log |
| `canopyLink` | Link clicks, including local file links |
| `InputWidthProbe.messageHandlerName` | Composer width measurement |

A new handler must also be added in `WebViewContainer.dismantleNSView`, the cached-webView reattach block, and `doReconnect` if it needs per-shim rewiring.

### History replay

`--resume` reconnects the CLI to a session but does not replay history to stdout. The extension reads the transcript itself and answers its webview's `get_session` request with the conversation. Canopy walks no transcript of its own for this; `ClaudeSessionHistory` lists sessions and locates transcripts.

For a remote client the daemon reshapes that `get_session` response on its way out (`ShimProcess`): base64 images of `Read` results become `canopy-asset` URLs fetched on demand, and the replay is cut at a turn boundary to fit under `mirrorReplayMaxBytes`.

A session can therefore resume and still draw an empty chat when the extension cannot read the transcript, as on SSH remote, where it is on the other machine.

## Known Limitations

- **Light theme only.** There is no dark mode.
- **SSH remote** renders no transcript replay, and `@` mentions read local files.
- **A Debug build cannot reproduce the firewall drop** that `MirrorRelay` works around; a Debug end-to-end run proves the relay switch-over only.
- **Extension DOM class-name suffixes churn between versions.** New selectors should match by shape (role, rect, border-radius), not by an exact class name.
