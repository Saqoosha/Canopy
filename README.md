English | [日本語](README.ja.md)

# Canopy

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="Canopy icon">
  <br>
  A standalone macOS app for <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> — no VSCode required. Runs the Claude Code extension's UI natively in a macOS window.
</p>

<p align="center">
  <img src="images/screenshot.png" width="800" alt="Canopy screenshot">
</p>

## Features

- **Native macOS window** — Claude Code's full React UI in a WKWebView
- **Launcher** — directory picker, recent directories, session history, model/effort/permission selectors, GitHub clone, and a "start in a new worktree" toggle
- **Sidebar shell** — sessions live in a persistent left sidebar; the detail pane swaps the active webview in place
- **Split view** — up to 6 panes side by side, Cmd+1–9 to focus one, drag the dividers to resize
- **Session resume** — pick up where you left off with instant history replay
- **Save and Quit** — the pane layout and every open session come back at the next launch
- **Named sessions** — titles generated outside the session's own context, renamable from the sidebar row or by double-clicking the pane header
- **Git aware** — the real branch in the sidebar and pane header, and a session that moves into a worktree is followed there
- **Peer names** — the name other Claude Code sessions use to message this one, shown on its row
- **Phone companion** — [Canopy Mobile](https://github.com/Saqoosha/Canopy-Mobile) shows every pane across every Mac and lets you answer a notification — free text or an AskUserQuestion option — as a real user turn
- **SSH remote** — run Claude CLI on remote machines via SSH
- **Claude Code on the Web** — teleport a cloud session down into a local one
- **Custom model providers** — point a session at any Anthropic-compatible endpoint, with per-tier model mapping
- **Session recap** — come back after being away and a summary of what happened sits above the composer
- **Warm cache** — an idle session gets one small turn every 55 minutes so its prompt cache doesn't lapse
- **Usage meters** — 5-hour and weekly rate-limit bars in the sidebar, per-pane context meter in the status bar
- **Real-time streaming** — thinking, text, and tool use streamed live, with inline image previews for file reads and a live subagent activity list
- **MacroPad** — optional USB key pad whose LEDs show each pane's activity and whose keys jump to it, so a session waiting on you is visible without looking at the screen. Drives over USB or over TCP from another Mac (firmware and printed case: [Canopy-MacroPad](https://github.com/Saqoosha/Canopy-MacroPad))
- **Auto-update** — Sparkle with delta updates
- **Keyboard shortcuts** — Cmd+N (new session), Cmd+O (open folder), Cmd+1–9 (focus pane), Cmd+Ctrl+1–9 (load the N-th session into the focused pane), Cmd+Shift+[ / ] (cycle the focused pane's session), Cmd+Opt+←/→ (move focus)
- **Custom styles** — refined typography, code block styling, and syntax highlighting that polish the extension's UI for a native macOS feel

## Requirements

- macOS 15.0 (Sequoia) or later
- [Claude Code VSCode extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code) installed
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude auth login`)
- Node.js 18+

---

## Development

### Architecture

```
WKWebView ─── postMessage ──→ ShimProcess.swift
                                  │ stdin/stdout NDJSON
                                  ▼
                              Node.js subprocess
                                  ├─ vscode-shim/ (10 JS modules)
                                  │    └─ intercepts require("vscode")
                                  └─ extension.js (CC extension, unmodified)
                                       └─ spawns Claude CLI via child_process
```

Canopy runs the CC extension's `extension.js` unmodified in a Node.js subprocess. A vscode-shim intercepts `require("vscode")` calls and bridges the webview via NDJSON over stdin/stdout. The extension spawns the Claude CLI in streaming JSON mode — SSE events flow through the shim directly to the webview.

For SSH remote, a wrapper script replaces the CLI spawn to run `claude` on the remote machine via SSH.

### Requirements

- Xcode 26 (the app does not compile under 16.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build from Source

```bash
git clone https://github.com/Saqoosha/Canopy.git
cd Canopy
xcodegen generate
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build

# The app is located at:
# build/Build/Products/Debug/Canopy.app
```

### Project Structure

```
Sources/Canopy/
  CanopyApp.swift              SwiftUI app entry, panes, menu commands, Sparkle updater
  AppState.swift               Observable state, PermissionMode enum, screen transitions
  SessionActivity.swift        One activity classification shared by the sidebar dot and the MacroPad LED
  MacroPad/                    USB key pad: wire protocol, serial/TCP device, session-state controller
  Roster/                      Phone companion: pane roster publisher, push notifier, replies
  SessionStore.swift           Sidebar + pane state, open/close, focus, pane ordering
  SessionRestoreSnapshot.swift Save-and-Quit snapshot and its restore rules
  KeepAliveCoordinator.swift   Prompt-cache keep-alive clock and fan-out
  RecapCoordinator.swift       Buys a session recap after you've been away
  SessionTitleGenerator.swift  Generates a title outside the session's own context
  ShimProcess.swift            Node.js subprocess manager, NDJSON bridge, auth/permission patching
  NodeDiscovery.swift          Finds Node.js >= 18 (Homebrew, mise, nvm, login shell)
  LauncherView.swift           Launcher: directory picker, recent dirs, session history
  WebViewContainer.swift       WKWebView setup, CC webview loading, CSS injection
  ClaudeSessionHistory.swift   Session JSONL parser, chain walking, cwd extraction
  StatusBarView.swift          Native status bar: context usage, model, rate limits
  ContentViewer.swift          Monaco editor overlay for viewing file contents
  theme-light.css              456 VSCode CSS variables (Default Light+)

Resources/
  vscode-shim/                 Node.js modules that shim the VSCode API
  ssh-claude-wrapper.sh        SSH remote wrapper script
  canopy-overrides.css         Custom styles: typography, code blocks, WKWebView fixes
  prism-canopy.css             Syntax highlighting theme (Prism.js, Claude Desktop colors)
```

### Tests

```bash
# Unit tests
node --test test/shim-unit.test.js

# Integration tests (needs CC extension installed)
node --test --test-timeout 120000 test/shim-integration.test.js
```

### Release

```bash
# Full release: build, sign, notarize, DMG, GitHub release, Sparkle appcast
./scripts/release.sh 1.0.2

# Update appcast only (after editing GitHub Release notes)
./scripts/update_appcast.sh 1.0.2
```

## Third-Party Libraries

- [Sparkle](https://github.com/sparkle-project/Sparkle) — Auto-update framework for macOS

## License

MIT
