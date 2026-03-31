# SSH Remote: Run Claude CLI on Remote Machines via SSH

**Date:** 2026-03-31
**Status:** Validated — prototype tested, ready for implementation

## Problem

Canopy runs Claude CLI locally. Users want to work on remote machines (dev servers, cloud VMs, other Macs) without installing Canopy there. The Claude CLI needs to run where the code lives — on the remote machine — while the UI stays local.

## Discovery & Validation (2026-03-31)

### Prototype Results

Tested with `ssh mbp` (macOS-to-macOS). All tests passed:

| Test | Result |
|------|--------|
| SSH connectivity (`ssh mbp echo "test"`) | OK |
| Remote Node.js (v22.21.1) | OK |
| Remote CC Extension installed | OK (v2.1.87) |
| Remote Claude CLI installed | OK (v2.1.88) |
| `spawnSync claude --version` via SSH | OK — returns "2.1.88 (Claude Code)" |
| `spawn claude -p --output-format stream-json` via SSH | OK — full NDJSON stream |
| Chat with Opus 4.6 via SSH | OK — "Hello from remote!" streamed correctly |
| All SSE event types received | OK — message_start, content_block_delta, message_stop, rate_limit_event |
| SSH `-T -o LogLevel=ERROR` flags | OK — no MOTD/banner corruption |
| stderr/stdout separation | OK |

### Key Architectural Insight

**The shim and extension.js run locally. Only the Claude CLI runs remotely.**

```
WKWebView ↔ ShimProcess.swift ↔ Node.js (shim + extension.js) ↔ SSH → remote claude CLI
              (local)              (local)                          (remote)
```

No need to deploy shim or extension to remote machine. The extension spawns the CLI via `child_process.spawn()` — we use the extension's native `claudeProcessWrapper` setting to redirect through SSH.

### `claudeProcessWrapper` — Extension's Official Hook

The CC extension has a VSCode setting `claudeCode.claudeProcessWrapper`:

```
"Claude Process Wrapper — Executable path used to launch the Claude process."
```

When set, the extension uses it as the executable and passes the original command + args as arguments:

```js
// Extension internal logic:
let wrapper = getConfig("claudeCode.claudeProcessWrapper");
if (wrapper) {
    args = [originalCommand, ...originalArgs];  // original becomes first arg
    if (nodePath) args.unshift(nodePath);       // node path prepended if exists
    command = wrapper;                           // wrapper becomes the command
}
spawn(command, args, { cwd, env, stdio: [...] });
```

This means a simple shell script wrapper that routes through SSH is all we need:

```bash
#!/bin/bash
# ssh-claude-wrapper.sh
exec ssh -T -o LogLevel=ERROR "$CANOPY_SSH_HOST" "$@"
```

**Zero monkey-patching. Zero Module hooks. The extension's own API handles everything.**

### How It Works End-to-End

1. User selects SSH host in LauncherView
2. Canopy writes `claudeCode.claudeProcessWrapper` → path to bundled wrapper script
3. Canopy sets `CANOPY_SSH_HOST` env var in ShimProcess
4. Shim starts, extension reads `claudeProcessWrapper` setting
5. Extension spawns: `ssh-claude-wrapper.sh [node] claude -p --output-format stream-json ...`
6. Wrapper does: `ssh -T -o LogLevel=ERROR mbp [node] claude -p --output-format stream-json ...`
7. NDJSON streams through SSH back to local extension → shim → webview

### Auth

Remote Claude CLI uses its own macOS Keychain for OAuth. User must run `claude login` on the remote machine once (via screen sharing or direct access). After that, CLI auth works via SSH.

### workspace.fs Limitation

The shim's `workspace.fs.readFile/stat/writeFile` operates on the local filesystem. For SSH remote, the cwd points to a remote path that doesn't exist locally. The Claude CLI itself handles all file operations on the remote machine — core chat functionality works. File listing for @-mentions is the main gap, deferrable to a future phase.

## Solution

Bundle a small SSH wrapper script in the app. When remote mode is active, set `claudeCode.claudeProcessWrapper` to the wrapper path and pass `CANOPY_SSH_HOST` via environment. The extension's native wrapper support handles the rest.

### Protocol

Zero protocol changes. SSH is transparent — stdin/stdout pass through SSH as-is. The existing NDJSON protocol works unmodified.

### Changes Required

1. **New resource: `ssh-claude-wrapper.sh`** — 3-line shell script (~5 lines)
2. **Swift `CanopySettings.swift`** — dynamic `claudeProcessWrapper` setting
3. **Swift `ShimProcess.swift`** — set `CANOPY_SSH_HOST` env var, set wrapper path
4. **Swift `AppState.swift`** — add `remoteHost` property
5. **Swift `LauncherView.swift`** — SSH host input field
6. **Swift `SSHHostStore.swift`** — persisted SSH host list
7. **Tests** — integration test with SSH

### What Works (Phase 1)
- Full chat with Claude (streaming, tool use, thinking)
- All SSE event types
- Session management (resume, history on remote)
- Permission modes
- Slash commands

### What Doesn't Work (Phase 1)
- `@`-mention file listing (workspace.fs is local)
- `open_file` / ContentViewer (files are on remote)
- Terminal opening (would need SSH terminal)

### Future Phases
- Phase 2: Remote file operations via SSH (`ssh host cat file`)
- Phase 3: SSH connection management (reconnect, keepalive)
- Phase 4: Linux remote support (XDG paths for globalState)
