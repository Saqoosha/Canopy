# Hangar

A standalone macOS application that hosts the Claude Code VSCode extension's webview UI in a native WKWebView window. Chat with Claude using the full Claude Code interface without running VSCode. Hangar loads the extension's bundled React UI directly, bridges the VSCode messaging protocol to a real Claude CLI process, and streams responses in real time.

<!-- TODO: Add screenshot -->
<!-- ![Hangar Screenshot](docs/screenshot.png) -->

## Features

- Native macOS window running the Claude Code extension UI (React 18 + Preact Signals)
- Real authentication via the installed Claude CLI (`claude auth status`)
- Full streaming chat powered by `claude` CLI in `stream-json` mode
- Real-time SSE event forwarding (thinking, text deltas, tool use) from CLI to webview
- VSCode Light+ theme with 456 CSS variables exported from a real VSCode instance
- Console log bridging from WKWebView JS to macOS unified logging (`os_log`)
- Safari Web Inspector support for debugging the webview

## Requirements

- macOS 15.0 or later
- [Claude Code VSCode extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code) installed (provides the webview assets at `~/.vscode/extensions/anthropic.claude-code-*/`)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude auth login`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation
- Xcode with macOS 15+ SDK

## Build

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build
xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/Hangar.app
```

Or open `Hangar.xcodeproj` in Xcode and build/run from there.

## How It Works

```
+------------------------------------------+
|  Hangar.app (macOS native window)        |
|                                          |
|  +------------------------------------+  |
|  |  WKWebView                         |  |
|  |                                    |  |
|  |  CC Extension React UI             |  |
|  |  (index.js + index.css from        |  |
|  |   ~/.vscode/extensions/...)        |  |
|  +--------+---------+-----------------+  |
|           |         ^                    |
|   postMessage    window.postMessage      |
|           |         |                    |
|  +--------v---------+-----------------+  |
|  |  WebViewMessageHandler             |  |
|  |  (protocol: init, auth, launch,    |  |
|  |   io_message, interrupt)           |  |
|  +--------+---------+-----------------+  |
|           |         ^                    |
|      stdin (NDJSON) | stdout (NDJSON)    |
|           |         |                    |
|  +--------v---------+-----------------+  |
|  |  ClaudeProcess                     |  |
|  |  claude -p --output-format         |  |
|  |    stream-json --input-format      |  |
|  |    stream-json --verbose           |  |
|  |    --include-partial-messages      |  |
|  +------------------------------------+  |
+------------------------------------------+
```

1. On launch, Hangar finds the installed CC extension under `~/.vscode/extensions/`
2. It writes an HTML entry point that loads the extension's JS/CSS with injected VSCode theme variables and API stubs
3. The webview's `acquireVsCodeApi()` is stubbed to bridge `postMessage` calls to Swift via `WKScriptMessageHandler`
4. When the user sends a message, Hangar spawns a `claude` CLI process in streaming JSON mode
5. CLI output (NDJSON lines containing Anthropic SSE events) is parsed and forwarded directly to the webview as `io_message` events
6. The webview renders streaming responses, tool use, thinking indicators, and all other Claude Code UI features

## Current Status

**Working (as of 2026-03-28):**
- Full chat with Claude via CLI bridge
- Real authentication (reads from Claude CLI auth)
- Streaming responses with real-time text deltas and thinking
- Tool use display (file edits, command execution, etc.)
- Light theme matching VSCode Default Light+

**Limitations:**
- Light theme only (no dark mode or system appearance switching)
- No session persistence or resume
- No MCP server integration
- No tab support or multi-window
- Model/thinking level selection UI present but changes not persisted to CLI
- Depends on Claude Code VSCode extension being installed for webview assets

## Project Structure

```
Sources/Hangar/
  HangarApp.swift              SwiftUI app entry point
  WebViewContainer.swift       WKWebView setup, HTML generation, console capture
  WebViewMessageHandler.swift  Protocol handler (auth, launch, IO bridge)
  ClaudeProcess.swift          Claude CLI lifecycle, NDJSON parsing, event forwarding
  VSCodeStub.swift             acquireVsCodeApi() JS stub, theme CSS loader
  CCExtension.swift            Extension/CLI path discovery
  theme-light.css              456 VSCode CSS variables (Default Light+)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed technical documentation and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the developer guide.

## License

MIT
