# SSH Connection Management (Phase 3) — Design Spec

## Problem

When an SSH connection drops during a remote Claude session, Canopy shows no indication. The UI appears stuck in "thinking" state indefinitely. The user has no way to know the connection died, and no way to recover without manually going back to the launcher.

### Worst-Case Scenario

Claude appears to be thinking (spinner active, no output) but the SSH tunnel is dead. The user waits minutes before realizing nothing will ever come back.

## Goals

1. **Detect disconnection quickly** — no more than 45 seconds of silent hang
2. **Notify the user immediately** — overlay on the current chat showing connection state
3. **Auto-reconnect** — restart the shim with `--resume SESSION_ID` to continue the session
4. **Manual fallback** — if auto-reconnect fails, provide retry button and launcher escape

## Non-Goals

- SSH ControlMaster / connection multiplexing (future optimization)
- Mosh support (incompatible — UDP, interactive only)
- Application-level heartbeat (SSH keepalive is sufficient; app heartbeat risks false positives during heavy CLI work)
- WebView recreation fallback (try overlay-only approach first)

## Architecture

### Current Flow (Phase 1)

```
ssh-claude-wrapper.sh
  └─ exec ssh -T -o LogLevel=ERROR host "cd dir && claude ..."
       └─ SSH dies → Process exits → terminationHandler → error message (dead end)
```

### New Flow (Phase 3) — Target Architecture

```
ssh-claude-wrapper.sh
  └─ exec ssh -T -o ServerAliveInterval=15 -o ServerAliveCountMax=3 ... host "cd dir && claude ..."
       └─ SSH dies (or keepalive timeout after 45s)
            → Process exits
            → terminationHandler
            → ShimProcess notifies delegate: didDisconnect
            → WebViewContainer shows overlay: "SSH disconnected — reconnecting..."
            → New ShimProcess created with --resume SESSION_ID
            → start() succeeds → overlay fades out
            → start() fails × 3 → overlay shows retry button
```

> **Known Limitation (Phase 3.1)**: SSH death kills the CLI subprocess, but the Node.js shim
> process remains alive. Because `terminationHandler` watches the shim (not the CLI),
> `shimProcessDidDisconnect` does not fire automatically. The CC extension detects CLI exit
> internally and shows an error banner (exit code 255). The reconnection framework is fully
> built — a future phase will add detection via shim stderr or extension message to trigger it.

## Detailed Design

### 1. SSH Keepalive

Add to `ssh-claude-wrapper.sh`:

```bash
exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" ...
```

- `ServerAliveInterval=15` — SSH client sends keepalive every 15 seconds over the encrypted channel
- `ServerAliveCountMax=3` — after 3 missed responses (45 seconds), SSH terminates the connection
- This covers: network drops, remote host crash, TCP half-open connections, laptop sleep/wake

When SSH terminates, the wrapper process (which `exec`'d into ssh) exits with non-zero status, triggering the existing `terminationHandler` in ShimProcess.

### 2. ShimProcess Changes

#### New Properties

```swift
/// Set to true when stop() is called explicitly (user action, not crash).
private var isIntentionalStop = false

/// Delegate for connection state notifications.
weak var delegate: ShimProcessDelegate?
```

#### Modified `stop()`

```swift
func stop() {
    isIntentionalStop = true
    // ... existing cleanup ...
}
```

#### Modified `handleProcessExit`

```swift
private func handleProcessExit(status: Int32, pid: pid_t) {
    // ... existing cleanup (readability handlers, descendant kill) ...

    if status != 0 && !isIntentionalStop && remoteHost != nil && activeSessionId != nil {
        // SSH disconnection detected — notify delegate for reconnection
        delegate?.shimProcessDidDisconnect(self)
    } else if status != 0 {
        showErrorInWebView("Claude process exited unexpectedly (status \(status)). Go back to launcher to restart.")
    }
}
```

Key conditions for auto-reconnect:
- Non-zero exit status (abnormal termination)
- Not intentionally stopped by user
- Is a remote session (has `remoteHost`)
- Has a session to resume (`activeSessionId`)

### 3. Delegate Protocol

```swift
protocol ShimProcessDelegate: AnyObject {
    func shimProcessDidDisconnect(_ shim: ShimProcess)
    func shimProcessDidReconnect(_ shim: ShimProcess)
    func shimProcessReconnectFailed(_ shim: ShimProcess)
}
```

Implemented by WebViewContainer to bridge connection state to the overlay UI.

### 4. Reconnection Logic

Owned by WebViewContainer (it manages the shim lifecycle).

```
On disconnect:
  1. Show overlay (state = .reconnecting, attempt = 1)
  2. Wait backoff interval
  3. Create new ShimProcess with same params + resumeSessionId = activeSessionId
  4. Set new shim's webView and delegate
  5. Call start()
  6. If success:
     - Swap shim reference
     - Call webViewDidFinishLoad() on new shim (webview is already loaded)
     - Notify delegate: didReconnect
     - Fade out overlay
  7. If failure:
     - Increment attempt
     - If attempt <= 3: go to step 2
     - Else: notify delegate: reconnectFailed, show retry button

Retry intervals (exponential backoff):
  Attempt 1: 3 seconds
  Attempt 2: 6 seconds
  Attempt 3: 12 seconds
```

The new ShimProcess inherits:
- `workingDirectory` (same remote path)
- `remoteHost` (same SSH host)
- `resumeSessionId` = old shim's `activeSessionId`
- `permissionMode` (same as before)
- `statusBarData` (same reference)
- `sessionTitle` (preserved from old shim)

### 5. Connection Overlay UI

New file: `ConnectionOverlayView.swift`

```swift
enum ConnectionState {
    case connected           // normal — overlay hidden
    case disconnected        // just detected — brief state before reconnecting
    case reconnecting(Int)   // attempt number (1-3)
    case reconnectFailed     // all retries exhausted
}
```

Visual design:
- Semi-transparent dark background (black, 0.6 opacity) over the WKWebView
- Centered card with:
  - **disconnected/reconnecting**: Network icon + "SSH connection lost" + spinner + "Reconnecting... (attempt N/3)"
  - **reconnectFailed**: Warning icon + "Could not reconnect" + "Retry" button + "Back to Launcher" button
- Fade in/out animations (0.3s)
- Chat content remains visible underneath (user can see where they left off)

Integrated in WebViewContainer via `.overlay()` modifier, controlled by `@State var connectionState: ConnectionState`.

### 6. Edge Cases

**User stops session during reconnection**: `stop()` sets `isIntentionalStop`, cancels any pending reconnect timer, dismisses overlay.

**Multiple rapid disconnections**: Each reconnect attempt creates a fresh ShimProcess. If a reconnect succeeds then immediately disconnects again, the cycle restarts from attempt 1.

**No activeSessionId yet**: If the SSH connection drops before the first message (no session created), don't attempt reconnect — just show the error. User hasn't invested anything yet.

**Local sessions**: Reconnection logic only activates for remote sessions (`remoteHost != nil`). Local process crashes show the existing error message.

## Files Changed

| File | Change |
|------|--------|
| `ssh-claude-wrapper.sh` | Add `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` |
| `ShimProcess.swift` | Add delegate protocol, `isIntentionalStop`, modify `handleProcessExit` |
| `WebViewContainer.swift` | Implement delegate, reconnection logic, overlay state management |
| `ConnectionOverlayView.swift` (new) | SwiftUI overlay for connection state display |

## Testing

1. **Keepalive test**: Start remote session, kill network (e.g., `networksetup -setairportpower en0 off`). Verify disconnect detected within ~45 seconds.
2. **Reconnect test**: After disconnect, restore network. Verify auto-reconnect succeeds and session continues.
3. **Retry exhaustion test**: Keep network off. Verify 3 attempts with backoff, then retry button shown.
4. **Intentional stop test**: Go back to launcher during active session. Verify no reconnect attempt.
5. **Pre-session disconnect test**: Connect SSH, disconnect before sending first message. Verify error shown (not reconnect loop).
