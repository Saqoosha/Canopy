# SSH Connection Management (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect SSH disconnections quickly (via keepalive), notify the user with an overlay, and auto-reconnect with `--resume`.

**Architecture:** SSH keepalive flags detect dead connections within 45s. ShimProcess notifies its delegate on abnormal exit. WebViewContainer's Coordinator handles reconnection by creating a new ShimProcess, swapping the WKScriptMessageHandler, and managing a connection overlay. ConnectionState is an `@Observable` class shared between Coordinator and SwiftUI overlay.

**Tech Stack:** Swift 6, SwiftUI, WKWebView, SSH keepalive

---

### Task 1: Add SSH Keepalive to Wrapper Script

**Files:**
- Modify: `Resources/ssh-claude-wrapper.sh:31-34`

- [ ] **Step 1: Add keepalive flags to SSH commands**

In `ssh-claude-wrapper.sh`, add `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` to both `ssh` invocations:

```bash
# Line 31: with CANOPY_SSH_CWD
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "cd '$CANOPY_SSH_CWD' && claude $*"
# Line 33: without CANOPY_SSH_CWD
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" claude "$@"
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n Resources/ssh-claude-wrapper.sh && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add Resources/ssh-claude-wrapper.sh
git commit -m "Add SSH keepalive to detect dead connections (15s interval, 3 max)"
```

---

### Task 2: Create ConnectionState Observable

**Files:**
- Create: `Sources/Canopy/ConnectionState.swift`

- [ ] **Step 1: Create ConnectionState**

```swift
import Foundation
import Observation

enum ConnectionStatus: Equatable {
    case connected
    case reconnecting(attempt: Int)
    case reconnectFailed
}

@Observable
final class ConnectionState {
    var status: ConnectionStatus = .connected

    var isOverlayVisible: Bool {
        status != .connected
    }

    var statusMessage: String {
        switch status {
        case .connected:
            return ""
        case .reconnecting(let attempt):
            return "Reconnecting... (\(attempt)/3)"
        case .reconnectFailed:
            return "Could not reconnect"
        }
    }
}
```

- [ ] **Step 2: Add to project.yml sources (verify auto-included)**

Canopy's `project.yml` uses `Sources/Canopy/**` glob — new files are auto-included. No change needed.

- [ ] **Step 3: Build to verify**

```bash
xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sources/Canopy/ConnectionState.swift
git commit -m "Add ConnectionState observable for SSH connection UI"
```

---

### Task 3: Create ConnectionOverlayView

**Files:**
- Create: `Sources/Canopy/ConnectionOverlayView.swift`

- [ ] **Step 1: Create overlay view**

```swift
import SwiftUI

struct ConnectionOverlayView: View {
    let connectionState: ConnectionState
    var onRetry: () -> Void
    var onBackToLauncher: () -> Void

    var body: some View {
        if connectionState.isOverlayVisible {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    statusIcon
                    Text("SSH Connection Lost")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(connectionState.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))

                    if case .reconnectFailed = connectionState.status {
                        HStack(spacing: 12) {
                            Button("Retry") { onRetry() }
                                .buttonStyle(.borderedProminent)
                            Button("Back to Launcher") { onBackToLauncher() }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: connectionState.status)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState.status {
        case .connected:
            EmptyView()
        case .reconnecting:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .reconnectFailed:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add Sources/Canopy/ConnectionOverlayView.swift
git commit -m "Add ConnectionOverlayView for SSH disconnect/reconnect display"
```

---

### Task 4: Add ShimProcessDelegate and Reconnection Support to ShimProcess

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift:14-15` (delegate property)
- Modify: `Sources/Canopy/ShimProcess.swift:238-251` (stop method)
- Modify: `Sources/Canopy/ShimProcess.swift:1061-1076` (handleProcessExit)

- [ ] **Step 1: Define ShimProcessDelegate protocol**

Add at the top of `ShimProcess.swift`, before the class definition (after line 7):

```swift
protocol ShimProcessDelegate: AnyObject {
    func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String)
    func shimProcessDidReconnect(_ shim: ShimProcess)
    func shimProcessReconnectFailed(_ shim: ShimProcess)
}
```

- [ ] **Step 2: Add delegate and isIntentionalStop properties**

Add to the ShimProcess property declarations (after `var statusBarData: StatusBarData?` on line 58):

```swift
weak var delegate: ShimProcessDelegate?
private var isIntentionalStop = false
```

- [ ] **Step 3: Modify stop() to set isIntentionalStop**

In the `stop()` method (line 238), add `isIntentionalStop = true` as the first line:

```swift
func stop() {
    isIntentionalStop = true
    guard let proc = process, proc.isRunning else { return }
    // ... rest unchanged ...
}
```

- [ ] **Step 4: Modify handleProcessExit for remote reconnection**

Replace the existing `handleProcessExit` (lines 1061-1076):

```swift
private func handleProcessExit(status: Int32, pid: pid_t) {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil

    if !descendantPids.isEmpty {
        Self.killProcessTree(descendantPids)
        descendantPids = []
    }

    if status != 0 && !isIntentionalStop && remoteHost != nil,
       let sessionId = activeSessionId
    {
        logger.error("SSH disconnection detected (status \(status)), requesting reconnect for session \(sessionId, privacy: .public)")
        delegate?.shimProcessDidDisconnect(self, sessionId: sessionId)
    } else if status != 0 && !isIntentionalStop {
        logger.error("Shim crashed (status \(status))")
        showErrorInWebView("Claude process exited unexpectedly (status \(status)). Go back to launcher to restart.")
    }
}
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/ShimProcess.swift
git commit -m "Add ShimProcessDelegate and reconnection-aware process exit handling"
```

---

### Task 5: Add Reconnection Logic to WebViewContainer

This is the core task. The `Coordinator` implements `ShimProcessDelegate`, manages reconnection attempts with exponential backoff, and swaps the `WKScriptMessageHandler` on the existing `WKWebView`.

**Files:**
- Modify: `Sources/Canopy/WebViewContainer.swift:7-13` (add connectionState property)
- Modify: `Sources/Canopy/WebViewContainer.swift:15-85` (Coordinator class)
- Modify: `Sources/Canopy/WebViewContainer.swift:89-144` (makeNSView — set delegate, store params)
- Modify: `Sources/Canopy/WebViewContainer.swift:149-160` (dismantleNSView — cancel reconnect)

- [ ] **Step 1: Add connectionState property to WebViewContainer**

Add to the WebViewContainer struct properties (after line 13 `var remoteHost: String?`):

```swift
var connectionState: ConnectionState?
```

- [ ] **Step 2: Add reconnection state to Coordinator**

Extend the Coordinator class with reconnection properties and the params needed to recreate a ShimProcess:

```swift
class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, ShimProcessDelegate {
    var shimProcess: ShimProcess?
    var consoleHandler: ConsoleLogHandler?
    var linkHandler: LinkClickHandler?
    var connectionState: ConnectionState?

    // Params needed to create a new ShimProcess on reconnect
    var workingDirectory: URL?
    var remoteHost: String?
    var permissionMode: PermissionMode = .acceptEdits
    var statusBarData: StatusBarData?

    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0
    private static let maxReconnectAttempts = 3
    private static let backoffIntervals: [TimeInterval] = [3, 6, 12]

    // ... existing delegate methods unchanged ...
```

- [ ] **Step 3: Implement ShimProcessDelegate in Coordinator**

Add these methods to the Coordinator class:

```swift
// MARK: - ShimProcessDelegate

func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String) {
    logger.info("SSH disconnected, starting reconnection for session \(sessionId, privacy: .public)")
    reconnectAttempt = 0
    connectionState?.status = .reconnecting(attempt: 1)
    attemptReconnect(sessionId: sessionId)
}

func shimProcessDidReconnect(_ shim: ShimProcess) {
    // Called externally if needed; primary success path is in attemptReconnect
}

func shimProcessReconnectFailed(_ shim: ShimProcess) {
    // Called externally if needed; primary failure path is in attemptReconnect
}

private func attemptReconnect(sessionId: String) {
    reconnectAttempt += 1
    let attempt = reconnectAttempt

    if attempt > Self.maxReconnectAttempts {
        logger.error("All reconnect attempts exhausted")
        connectionState?.status = .reconnectFailed
        return
    }

    let delay = Self.backoffIntervals[min(attempt - 1, Self.backoffIntervals.count - 1)]
    logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) in \(delay)s")
    connectionState?.status = .reconnecting(attempt: attempt)

    reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
        self?.doReconnect(sessionId: sessionId)
    }
}

private func doReconnect(sessionId: String) {
    guard let webView = shimProcess?.webView,
          let workingDirectory,
          let remoteHost
    else {
        logger.error("Reconnect failed: missing webView or params")
        connectionState?.status = .reconnectFailed
        return
    }

    // Clean up old shim's message handler
    let ucc = webView.configuration.userContentController
    ucc.removeScriptMessageHandler(forName: "vscodeHost")
    shimProcess = nil

    // Create new ShimProcess with --resume
    let newShim = ShimProcess(
        workingDirectory: workingDirectory,
        resumeSessionId: sessionId,
        permissionMode: permissionMode,
        sessionTitle: nil, // title preserved in webview
        statusBarData: statusBarData,
        remoteHost: remoteHost
    )
    newShim.delegate = self
    newShim.webView = webView
    ucc.add(newShim, name: "vscodeHost")

    if newShim.start() {
        logger.info("Reconnect succeeded")
        shimProcess = newShim
        reconnectAttempt = 0
        connectionState?.status = .connected
        // Tell shim the webview is ready (it's already loaded)
        newShim.webViewDidFinishLoad()
    } else {
        logger.error("Reconnect attempt \(self.reconnectAttempt) failed: shim start returned false")
        // Remove the failed handler
        ucc.removeScriptMessageHandler(forName: "vscodeHost")
        attemptReconnect(sessionId: sessionId)
    }
}

func cancelReconnect() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    reconnectAttempt = 0
}

func retryReconnect() {
    guard let sessionId = shimProcess?.activeSessionId
          ?? (connectionState?.status == .reconnectFailed ? nil : nil)
    else { return }
    // For retry after failure, we need the session ID stored somewhere
    reconnectAttempt = 0
    connectionState?.status = .reconnecting(attempt: 1)
    attemptReconnect(sessionId: sessionId)
}
```

- [ ] **Step 4: Store reconnection params in makeNSView**

In `makeNSView`, after creating the shim (around line 126), store the params and set the delegate:

```swift
let shim = ShimProcess(
    workingDirectory: workingDirectory,
    resumeSessionId: resumeSessionId,
    permissionMode: permissionMode,
    sessionTitle: sessionTitle,
    statusBarData: statusBarData,
    remoteHost: remoteHost
)
ucc.add(shim, name: "vscodeHost")
shim.delegate = context.coordinator
context.coordinator.shimProcess = shim
context.coordinator.consoleHandler = consoleHandler
context.coordinator.linkHandler = linkHandler
context.coordinator.connectionState = connectionState
context.coordinator.workingDirectory = workingDirectory
context.coordinator.remoteHost = remoteHost
context.coordinator.permissionMode = permissionMode
context.coordinator.statusBarData = statusBarData
```

- [ ] **Step 5: Cancel reconnect on dismantle**

In `dismantleNSView`, add cancellation before stopping:

```swift
static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.cancelReconnect()
    let ucc = nsView.configuration.userContentController
    // ... rest unchanged ...
}
```

- [ ] **Step 6: Expose activeSessionId on ShimProcess**

The `retryReconnect` method needs access to the session ID. We need to store it in the Coordinator when disconnect happens. Modify `shimProcessDidDisconnect` to store the session ID:

Add a property to Coordinator:

```swift
private var lastDisconnectedSessionId: String?
```

Update `shimProcessDidDisconnect`:

```swift
func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String) {
    logger.info("SSH disconnected, starting reconnection for session \(sessionId, privacy: .public)")
    lastDisconnectedSessionId = sessionId
    reconnectAttempt = 0
    connectionState?.status = .reconnecting(attempt: 1)
    attemptReconnect(sessionId: sessionId)
}
```

Update `retryReconnect`:

```swift
func retryReconnect() {
    guard let sessionId = lastDisconnectedSessionId else {
        logger.warning("retryReconnect: no session ID available")
        return
    }
    reconnectAttempt = 0
    connectionState?.status = .reconnecting(attempt: 1)
    attemptReconnect(sessionId: sessionId)
}
```

- [ ] **Step 7: Build to verify**

```bash
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 8: Commit**

```bash
git add Sources/Canopy/WebViewContainer.swift
git commit -m "Add SSH reconnection logic to WebViewContainer Coordinator"
```

---

### Task 6: Wire Overlay into TabContentView

**Files:**
- Modify: `Sources/Canopy/CanopyApp.swift:163-185` (TabContentView)

- [ ] **Step 1: Add connectionState to TabContentView**

Add `@State private var connectionState = ConnectionState()` to TabContentView (after line 165):

```swift
struct TabContentView: View {
    @State private var appState = AppState()
    @State private var statusBarData = StatusBarData()
    @State private var connectionState = ConnectionState()
```

- [ ] **Step 2: Pass connectionState and add overlay**

Update the session case in the body:

```swift
case .session:
    VStack(spacing: 0) {
        WebViewContainer(
            workingDirectory: appState.workingDirectory,
            resumeSessionId: appState.resumeSessionId,
            permissionMode: appState.permissionMode,
            sessionTitle: appState.resumeSessionTitle,
            statusBarData: statusBarData,
            remoteHost: appState.remoteHost,
            connectionState: connectionState
        )
        .overlay {
            ConnectionOverlayView(
                connectionState: connectionState,
                onRetry: { connectionState.status = .reconnecting(attempt: 1) },
                onBackToLauncher: {
                    connectionState.status = .connected
                    appState.backToLauncher()
                }
            )
        }
        StatusBarView(data: statusBarData)
    }
    .id(appState.webviewReloadToken)
```

- [ ] **Step 3: Fix onRetry to actually trigger reconnection**

The `onRetry` closure needs to reach the Coordinator. Since `ConnectionOverlayView` can't directly access the Coordinator, we use a callback pattern. Update `ConnectionState` to hold a retry closure:

In `ConnectionState.swift`, add:

```swift
@Observable
final class ConnectionState {
    var status: ConnectionStatus = .connected
    /// Called when user taps "Retry" button. Set by Coordinator.
    var onRetry: (() -> Void)?

    // ... rest unchanged ...
}
```

In `ConnectionOverlayView`, update the Retry button:

```swift
Button("Retry") {
    connectionState.onRetry?()
}
```

In WebViewContainer's Coordinator, in `shimProcessDidDisconnect`:

```swift
func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String) {
    logger.info("SSH disconnected, starting reconnection for session \(sessionId, privacy: .public)")
    lastDisconnectedSessionId = sessionId
    reconnectAttempt = 0
    connectionState?.status = .reconnecting(attempt: 1)
    connectionState?.onRetry = { [weak self] in
        self?.retryReconnect()
    }
    attemptReconnect(sessionId: sessionId)
}
```

In `TabContentView`, simplify the overlay:

```swift
.overlay {
    ConnectionOverlayView(
        connectionState: connectionState,
        onRetry: { connectionState.onRetry?() },
        onBackToLauncher: {
            connectionState.status = .connected
            appState.backToLauncher()
        }
    )
}
```

- [ ] **Step 4: Reset connectionState on new session**

In `TabContentView`, reset connectionState when webviewReloadToken changes. Add to `.id(appState.webviewReloadToken)`:

```swift
.id(appState.webviewReloadToken)
.onChange(of: appState.webviewReloadToken) {
    connectionState.status = .connected
    connectionState.onRetry = nil
}
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/CanopyApp.swift Sources/Canopy/ConnectionState.swift Sources/Canopy/ConnectionOverlayView.swift
git commit -m "Wire ConnectionOverlayView into TabContentView for SSH disconnect UI"
```

---

### Task 7: Update CLAUDE.md and Design Doc

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add ConnectionState and ConnectionOverlayView to Key Source Files**

In the Swift section of CLAUDE.md, add:

```markdown
- `ConnectionState.swift` — Observable connection status (connected, reconnecting, failed) for SSH overlay
- `ConnectionOverlayView.swift` — SwiftUI overlay showing SSH disconnect/reconnect state
```

- [ ] **Step 2: Update SSH Remote section**

Replace the Phase 1 Limitations section with:

```markdown
### Connection Management (Phase 3)
- SSH keepalive: `ServerAliveInterval=15`, `ServerAliveCountMax=3` — detects dead connections within 45s
- Auto-reconnect: 3 attempts with exponential backoff (3s, 6s, 12s), uses `--resume SESSION_ID`
- UI overlay: semi-transparent overlay on webview showing disconnect/reconnect state
- Only activates for remote sessions with an established session ID

### Remaining Limitations
- `@`-mention file listing doesn't work (workspace.fs is local)
- `open_file` / ContentViewer can't read remote files
```

- [ ] **Step 3: Update Next Steps**

```markdown
## Next Steps
1. SSH remote Phase 2 — remote file operations via SSH for @-mention support
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md with Phase 3 connection management details"
```

---

### Task 8: End-to-End Testing

Manual testing checklist — no automated tests for SSH connection behavior.

- [ ] **Step 1: Build and run**

```bash
xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Canopy.app
```

- [ ] **Step 2: Test keepalive detection**

1. Start SSH remote session to a known host
2. Send a message and get a response (establishes session ID)
3. Kill network: `networksetup -setairportpower en0 off` (or disconnect Wi-Fi)
4. Wait ~50 seconds
5. Verify: overlay appears with "SSH Connection Lost" + "Reconnecting... (1/3)"
6. Restore network: `networksetup -setairportpower en0 on`
7. Verify: reconnection succeeds, overlay fades out, session continues

- [ ] **Step 3: Test retry exhaustion**

1. Start SSH remote session, send a message
2. Kill network and keep it off
3. Verify: overlay shows attempts 1/3, 2/3, 3/3 with increasing delays
4. After all fail: "Could not reconnect" with Retry and Back to Launcher buttons
5. Click "Back to Launcher" — returns to launcher, no crash

- [ ] **Step 4: Test intentional stop**

1. Start SSH remote session
2. Press Cmd+N (back to launcher) while session active
3. Verify: NO reconnect overlay appears, clean return to launcher

- [ ] **Step 5: Test pre-session disconnect**

1. Start SSH remote session to a host that's unreachable
2. Verify: error message shown (not reconnect loop — no session ID yet)

- [ ] **Step 6: Test local session unaffected**

1. Start local (non-SSH) session
2. Verify: no reconnection behavior, no overlay, works as before
