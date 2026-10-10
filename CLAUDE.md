# Canopy — Claude Code Extension Webview Host

macOS native app that hosts the Claude Code VSCode extension's webview (React UI) in a WKWebView. No VSCode required: a Node subprocess runs the extension's `extension.js` unmodified behind a `vscode` shim, and the extension spawns the Claude CLI. Sessions live in a per-Mac daemon (`canopyd`); the GUI, other Macs and the phone are clients.

```
Canopy.app (GUI) ── Unix socket ──┐
another Mac      ── TCP/Tailscale ┤
Canopy Mobile    ── TCP/Tailscale ┤
                                  ▼
canopyd (Canopy --daemon, LaunchAgent, no NSApplication)
  ├─ ControlSession / MirrorServer / RosterPublisher
  └─ ShimProcess × N ── NDJSON ── node vscode-shim + extension.js ── claude CLI

SSH remote sessions are the exception: their ShimProcess stays in the GUI
(`OpenSession.isDaemonHosted` is false for `.remote`), and the wrapper runs `ssh host claude`.
```

## Detail lives in `docs/notes/`

This file holds only what applies to every task. Everything else lives in `docs/notes/`. **Read the matching note before touching that area.** Code comments that say "see CLAUDE.md" refer to the old 297 KB version. Grep `docs/notes/` for the quoted phrase; if it was condensed away, read the original with `git show 3b6a198:CLAUDE.md`.

| Area | Note |
|---|---|
| Per-file hazards not on the code's own doc comments | `source-files.md` |
| Feature overview (multi-pane, MacroPad, Canopy Server, Sparkle, SSH) | `features.md` |
| Toolchain, signing, bundle ids, theme CSS | `build-and-toolchain.md` |
| Webview ↔ host protocol, mirror wire format, CLI flags | `protocol.md` |
| Shortcuts, pane/row ordering, Save-and-Quit restore, resume | `session-management.md` |
| Tests, CI count floors, the logic probe, mutation testing | `testing.md` |
| Release scripts, appcast, notarize hangs, codesign retry | `release.md` |
| SSH remote | `ssh-remote.md` |
| Topic learnings | `learnings-<topic>.md`: shim-specific, multi-pane-layout, macropad, first-render-races, prompt-cache-keep-alive, phone-reply-queue, background-task-reconcile, session-relocation, launch-composer, worktree-launch, session-titles, peer-names, rate-limits-per-account, general |

Also: `docs/architecture.html` (walkthrough, mirrored to `gh-pages`), `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, `docs/CONTROL_PROTOCOL.md`, design specs under `docs/superpowers/specs/`.

**Where new knowledge goes.** A learning about one area goes into its `docs/notes/` file, not here. A measured number belongs on the code's doc comment; notes link to it rather than restating it. Add a line here only if it bites on any task. Correct a wrong claim by deleting it, not by appending a correction beside it.

## Build

```bash
./scripts/build_debug_stable.sh   # Apple Development signing; TCC grants persist
open build/Build/Products/Debug/Canopy.app
```

- **Needs an Xcode 26 toolchain.** Xcode 16.4 fails with ~20 actor-isolation errors. `SWIFT_VERSION: "6.0"` is the language mode, not the compiler.
- **Never use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) for interactive dev.** It re-triggers TCC on every launch. CI is the only exception.
- `project.yml` is the source of truth; `Canopy.xcodeproj` is gitignored. Run `xcodegen generate` after editing it. An Xcode GUI build does not regenerate.
- The Debug bundle id is `sh.saqoo.Canopy.debug`, so `defaults write` must target that domain. Two things are still SHARED with the installed Release build:
  - `~/Library/Application Support/Canopy/`, including `settings.json`
  - the `Logger` subsystem `sh.saqoo.Canopy`
- Sparkle is pinned with `exactVersion:` in `project.yml`. Never go below 2.9.2.

## Tests

```bash
node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)   # shim unit
node --test --test-timeout 120000 test/shim-integration.test.js                       # needs CC extension
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy  # Swift probe, ~3 s
```

- CI asserts count floors (`EXPECTED_TESTS`, `EXPECTED_ASSERTIONS` in `ci.yml`). Removing tests costs an edit there. When a merge conflicts on a floor, build the merged tree and read the real count. Do not pick a side.
- Every file under `test/` must appear in one of `CI_TEST_FILES` / `EXCLUDED_TEST_FILES` / `NON_TEST_FILES`.
- A probe fixture derives production constants instead of retyping their values. It forces any live setting it depends on, and restores it in a `defer`.
- The probe writes real UserDefaults keys and `~/.claude` fixtures. See `testing.md`.
- A test proves something only if reverting the fix, one fix at a time, turns it red.

## Traps that fail silently

- **jj-colocated repo.** git HEAD sits detached at `main`, so `git checkout -- <path>` writes main's copy over the branch's work. Back files up with `cp`. To recover, use `jj op log` + `jj restore --from <commit> <paths>`.
- **Unified log.**
  - Call `/usr/bin/log`. A bare `log` hits a shell builtin.
  - `debug` is never stored: `log show --debug` returns nothing, so use `log stream --level debug`. `info` is a short ring buffer, so anything read later must be `notice`.
  - `process == "Canopy"` matches Debug and Release together. Filter by `Canopy[<pid>`.
  - String interpolations show as `<private>` unless marked `privacy: .public`.
- **`@MainActor` inference.** `ShimProcess` and other `WKScriptMessageHandler` conformers are wholly `@MainActor`, statics included. A closure literal written in them and passed to a non-`@Sendable` callback aborts the process when it runs off main (`DispatchSource` handlers, `enumerateMatches`). Mark the member `nonisolated`.
- **WKScriptMessageHandlers.** A new handler must also be added in three places: `WebViewContainer.dismantleNSView`, the cached-webView reattach block, and `doReconnect` (if it needs per-shim rewiring).
- **Multi-pane layout.**
  - `preferredWidth` is a weight. Call `normalizePaneWeightsToVisualWidths()` before any code that treats it as pt.
  - Never put `.ignoresSafeArea(edges: .top)` on an ancestor of `WeightedPaneLayout`. It freezes the panes on resize.
  - Make pane-header controls hit-testable from the NSEvent monitor; on macOS 26 a `BackdropView` covers that band, so SwiftUI does not get the clicks.
- **Subprocess stdin pipes need `F_SETNOSIGPIPE`.** Without it, SIGPIPE kills the app inside `write(2)`, and `do/catch` never runs.
- **`WindowGroup` `.task` runs before the probe exits.** A task that reaches credentials, the network or another process needs a `CANOPY_RUN_LOGIC_PROBE` guard.
- **Wire shapes.** Dump a message's shape at the point you hook it. A downstream consumer sees an already-unwrapped envelope.
- **Swift doc comments.** Inserting a declaration between a `///` block and its subject silently moves the doc to the new declaration. Leave a blank line, and check both symbols.
- **CLI internals.** The binary lives at `~/.local/share/claude/versions/<v>`. Always grep it with `-a`, because a silent grep means "binary skipped", not "absent". Bound context patterns (`.\{0,200\}`). Prefer capturing `stream-json` over reading the binary, and test the DEFAULT invocation first. Never pass `--bare`.
- **CC extension DOM.** Class-name suffixes churn between versions. Select by shape (role, rect, border-radius), never by class name.
