# SSH Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Claude CLI on a remote machine via SSH while keeping the UI, shim, and extension local.

**Architecture:** Use the CC extension's native `claudeCode.claudeProcessWrapper` setting. Bundle a small SSH wrapper script. When remote mode is active, set the wrapper path in Canopy settings and pass `CANOPY_SSH_HOST` env var. Zero monkey-patching — the extension handles everything natively.

**Tech Stack:** Shell script (wrapper), Swift/SwiftUI (UI), SSH (transport)

---

## File Structure

### New Files
- `Resources/ssh-claude-wrapper.sh` — SSH wrapper script (~5 lines)
- `Sources/Canopy/SSHHostStore.swift` — persisted SSH host list (~40 lines)

### Modified Files
- `Sources/Canopy/ShimProcess.swift` — set `CANOPY_SSH_HOST` env + wrapper path in settings
- `Sources/Canopy/AppState.swift` — `remoteHost: String?` property
- `Sources/Canopy/CanopyApp.swift` — pass `remoteHost` to WebViewContainer
- `Sources/Canopy/WebViewContainer.swift` — pass `remoteHost` to ShimProcess
- `Sources/Canopy/LauncherView.swift` — SSH host picker in UI
- `Sources/Canopy/SettingsView.swift` — manage saved SSH hosts
- `Sources/Canopy/StatusBarData.swift` — remote indicator
- `Sources/Canopy/StatusBarView.swift` — display remote indicator
- `project.yml` — add ssh-claude-wrapper.sh to bundle resources

---

### Task 1: Create SSH wrapper script

**Files:**
- Create: `Resources/ssh-claude-wrapper.sh`

- [ ] **Step 1: Create the wrapper script**

Create `Resources/ssh-claude-wrapper.sh`:

```bash
#!/bin/bash
# SSH Claude Process Wrapper for Canopy
# Called by CC extension as: wrapper [nodePath] command [args...]
# Routes all arguments to the remote host via SSH.
exec ssh -T -o LogLevel=ERROR "$CANOPY_SSH_HOST" "$@"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x Resources/ssh-claude-wrapper.sh`

- [ ] **Step 3: Test manually**

Run: `CANOPY_SSH_HOST=mbp Resources/ssh-claude-wrapper.sh claude --version`
Expected: `2.1.88 (Claude Code)` (or current version on remote)

- [ ] **Step 4: Add to project.yml bundle resources**

In `project.yml`, find the resources section for Canopy target and add:

```yaml
- path: Resources/ssh-claude-wrapper.sh
```

Verify it's alongside the existing `Resources/vscode-shim` entry.

- [ ] **Step 5: Verify it gets bundled**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Then: `ls build/Build/Products/Debug/Canopy.app/Contents/Resources/ssh-claude-wrapper.sh`
Expected: File exists in bundle

- [ ] **Step 6: Commit**

```bash
git add Resources/ssh-claude-wrapper.sh project.yml
git commit -m "Add SSH wrapper script for remote Claude CLI

- 5-line shell script routes commands via ssh to CANOPY_SSH_HOST
- Bundled in app resources for use with claudeProcessWrapper setting"
```

---

### Task 2: SSHHostStore — persist saved hosts

**Files:**
- Create: `Sources/Canopy/SSHHostStore.swift`

- [ ] **Step 1: Create SSHHostStore**

```swift
import Foundation

/// Persists SSH host entries (e.g. "mbp", "user@server") in UserDefaults.
enum SSHHostStore {
    private static let key = "sshHosts"

    static func hosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ host: String) {
        var list = hosts().filter { $0 != host }
        list.insert(host, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ host: String) {
        let list = hosts().filter { $0 != host }
        UserDefaults.standard.set(list, forKey: key)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Canopy/SSHHostStore.swift
git commit -m "Add SSHHostStore for persisting SSH remote hosts

- UserDefaults-backed MRU list, max 10 entries"
```

---

### Task 3: Thread `remoteHost` through AppState → WebViewContainer → ShimProcess

**Files:**
- Modify: `Sources/Canopy/AppState.swift`
- Modify: `Sources/Canopy/CanopyApp.swift`
- Modify: `Sources/Canopy/WebViewContainer.swift`
- Modify: `Sources/Canopy/ShimProcess.swift:59` (init signature)

- [ ] **Step 1: Add remoteHost to AppState**

In `AppState.swift`, after `resumeSessionTitle` (line 39):

```swift
var remoteHost: String?
```

Update `launchSession` signature and body:

```swift
func launchSession(directory: URL, resumeSessionId: String? = nil, sessionTitle: String? = nil, remoteHost: String? = nil) {
    RecentDirectories.add(directory)
    workingDirectory = directory
    self.resumeSessionId = resumeSessionId
    self.resumeSessionTitle = sessionTitle
    self.remoteHost = remoteHost
    statusBarData?.resetAll()
    webviewReloadToken += 1
    screen = .session
    logger.info("Launching session: dir=\(directory.path, privacy: .public) resume=\(resumeSessionId ?? "new", privacy: .public) mode=\(self.permissionMode.rawValue, privacy: .public) remote=\(remoteHost ?? "local", privacy: .public)")
}
```

- [ ] **Step 2: Pass remoteHost in CanopyApp.swift TabContentView**

In `TabContentView.body`, update the `WebViewContainer` initializer:

```swift
WebViewContainer(
    workingDirectory: appState.workingDirectory,
    resumeSessionId: appState.resumeSessionId,
    permissionMode: appState.permissionMode,
    sessionTitle: appState.resumeSessionTitle,
    statusBarData: statusBarData,
    remoteHost: appState.remoteHost
)
```

- [ ] **Step 3: Add remoteHost to WebViewContainer**

In `WebViewContainer.swift`, add the property (after `statusBarData`):

```swift
var remoteHost: String?
```

Find where `ShimProcess` is initialized in `makeNSView(context:)` and pass `remoteHost`:

```swift
let shim = ShimProcess(
    workingDirectory: workingDirectory,
    resumeSessionId: resumeSessionId,
    permissionMode: permissionMode,
    sessionTitle: sessionTitle,
    statusBarData: statusBarData,
    remoteHost: remoteHost
)
```

- [ ] **Step 4: Add remoteHost to ShimProcess init**

In `ShimProcess.swift`, add stored property after `permissionMode` (line 46):

```swift
var remoteHost: String?
```

Update init signature:

```swift
init(workingDirectory: URL, resumeSessionId: String? = nil, permissionMode: PermissionMode = .acceptEdits, sessionTitle: String? = nil, statusBarData: StatusBarData? = nil, remoteHost: String? = nil) {
```

Add in init body (after `self.statusBarData = statusBarData`):

```swift
self.remoteHost = remoteHost
```

- [ ] **Step 5: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/AppState.swift Sources/Canopy/CanopyApp.swift Sources/Canopy/WebViewContainer.swift Sources/Canopy/ShimProcess.swift
git commit -m "Thread remoteHost through AppState → WebViewContainer → ShimProcess

- Add remoteHost to AppState.launchSession
- Pass through TabContentView → WebViewContainer → ShimProcess init"
```

---

### Task 4: ShimProcess — set env var and wrapper path for SSH remote

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift:121-152` (start method)

This is the core task. When `remoteHost` is set, ShimProcess must:
1. Set `CANOPY_SSH_HOST` env var so the wrapper script knows the target
2. Write `claudeCode.claudeProcessWrapper` to Canopy settings so the extension uses it

- [ ] **Step 1: Set CANOPY_SSH_HOST env var in start()**

In `ShimProcess.swift`, `start()` method, find where `env` is built (around line 132). Add after `env["HOME"] = ...`:

```swift
// SSH remote: set host for wrapper script
if let remote = remoteHost {
    env["CANOPY_SSH_HOST"] = remote
}
```

- [ ] **Step 2: Find wrapper script path from bundle**

Add a static method to find the wrapper:

```swift
private static func findWrapperPath() -> String? {
    Bundle.main.path(forResource: "ssh-claude-wrapper", ofType: "sh")
}
```

- [ ] **Step 3: Set/clear claudeProcessWrapper in settings before launch**

In `start()`, before the process runs (after env setup, around line 150), manage the wrapper setting dynamically. Rather than modifying CanopySettings permanently, write it directly to the settings JSON:

```swift
// Set or clear claudeProcessWrapper based on remote mode
if let remote = remoteHost, let wrapperPath = Self.findWrapperPath() {
    CanopySettings.shared.setProcessWrapper(wrapperPath)
    logger.info("SSH remote mode: host=\(remote, privacy: .public) wrapper=\(wrapperPath, privacy: .public)")
} else {
    CanopySettings.shared.setProcessWrapper(nil)
}
```

- [ ] **Step 4: Add setProcessWrapper to CanopySettings**

In `CanopySettings.swift`, add a method to set/clear the wrapper:

```swift
func setProcessWrapper(_ path: String?) {
    // Read current settings, update just this key, write back
    var dict: [String: Any] = [:]
    if let data = try? Data(contentsOf: filePath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        dict = existing
    }
    if let path {
        dict["claudeCode.claudeProcessWrapper"] = path
    } else {
        dict.removeValue(forKey: "claudeCode.claudeProcessWrapper")
    }
    do {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: filePath)
    } catch {
        logger.error("Failed to save processWrapper: \(error.localizedDescription, privacy: .public)")
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Manual smoke test**

Run the app, select a directory, enable SSH remote with host "mbp", start session. Check Console.app for:
- `SSH remote mode: host=mbp wrapper=/path/to/ssh-claude-wrapper.sh`
- Extension stderr should show the wrapper being invoked

- [ ] **Step 7: Commit**

```bash
git add Sources/Canopy/ShimProcess.swift Sources/Canopy/CanopySettings.swift
git commit -m "Wire SSH remote via claudeProcessWrapper setting

- Set CANOPY_SSH_HOST env var for wrapper script
- Write claudeProcessWrapper to Canopy settings when remote mode active
- Clear wrapper setting when not in remote mode
- Add setProcessWrapper to CanopySettings"
```

---

### Task 5: LauncherView — SSH host picker UI

**Files:**
- Modify: `Sources/Canopy/LauncherView.swift`

- [ ] **Step 1: Add SSH state variables**

Add to `LauncherView` state vars (after `isDropTargeted`):

```swift
@State private var remoteHost: String = ""
@State private var savedHosts: [String] = []
@State private var isRemoteMode = false
```

- [ ] **Step 2: Add SSH toggle and host card to UI**

In the body VStack, add after `directoryCard` and before `startButton`:

```swift
Toggle("SSH Remote", isOn: $isRemoteMode)
    .toggleStyle(.switch)
    .padding(.horizontal)

if isRemoteMode {
    sshHostCard
}
```

Add the SSH host card computed property:

```swift
// MARK: - SSH Host Card

private var sshHostCard: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("SSH Host")
            .font(.headline)

        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(!remoteHost.isEmpty ? Color.blue : Color.secondary)
                .font(.title3)

            TextField("hostname or user@host", text: $remoteHost)
                .textFieldStyle(.plain)
                .onSubmit { startSession() }

            if !savedHosts.isEmpty {
                Menu {
                    ForEach(savedHosts, id: \.self) { host in
                        Button(host) { remoteHost = host }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
```

- [ ] **Step 3: Update start session to pass remoteHost**

Find the existing start button action and update to pass remote host. Add a helper:

```swift
private func startSession() {
    guard let dir = selectedDirectory else { return }
    let remote = isRemoteMode && !remoteHost.isEmpty ? remoteHost : nil
    if let remote {
        SSHHostStore.add(remote)
        savedHosts = SSHHostStore.hosts()
    }
    appState.launchSession(directory: dir, remoteHost: remote)
}
```

Update the start button to call `startSession()` and also pass `remoteHost` for any other launch paths (recent directory clicks, session resume clicks, drag-and-drop).

- [ ] **Step 4: Load saved hosts in loadData**

In the existing `loadData` function, add:

```swift
savedHosts = SSHHostStore.hosts()
```

- [ ] **Step 5: Disable start button when remote mode but no host**

Update the start button's disabled condition to include:

```swift
.disabled(selectedDirectory == nil || (isRemoteMode && remoteHost.isEmpty))
```

- [ ] **Step 6: Build and verify visually**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Then: `open build/Build/Products/Debug/Canopy.app`
Verify: Toggle "SSH Remote" shows the host input field with recent hosts dropdown.

- [ ] **Step 7: Commit**

```bash
git add Sources/Canopy/LauncherView.swift
git commit -m "Add SSH host picker to LauncherView

- Toggle for SSH Remote mode
- Text field with hostname input
- Recent hosts dropdown from SSHHostStore
- Start button disabled until host is entered in remote mode"
```

---

### Task 6: Window title and status bar — remote indicator

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift` (window title)
- Modify: `Sources/Canopy/StatusBarData.swift`
- Modify: `Sources/Canopy/StatusBarView.swift`
- Modify: `Sources/Canopy/SettingsView.swift`

- [ ] **Step 1: Prepend [host] to window title**

In `ShimProcess.swift`, find `refreshWindowTitle()`. Update to prepend remote host:

```swift
private func refreshWindowTitle() {
    guard let window = webView?.window else { return }
    let prefix = remoteHost != nil ? "[\(remoteHost!)] " : ""
    let title = sessionTitle.isEmpty ? "Canopy" : sessionTitle
    window.title = prefix + title
}
```

- [ ] **Step 2: Add remoteHost to StatusBarData**

In `StatusBarData.swift`, add:

```swift
var remoteHost: String?
```

In `ShimProcess.swift` init, after setting `self.remoteHost`:

```swift
statusBarData?.remoteHost = remoteHost
```

- [ ] **Step 3: Show remote indicator in StatusBarView**

In `StatusBarView.swift`, add near the model/version display:

```swift
if let remote = data.remoteHost {
    HStack(spacing: 3) {
        Image(systemName: "network")
            .font(.system(size: 9))
        Text(remote)
    }
    .foregroundStyle(.secondary)
    .font(.system(size: 11, design: .monospaced))
}
```

- [ ] **Step 4: Add SSH host management to SettingsView**

In `SettingsView.swift`, add state var:

```swift
@State private var sshHosts: [String] = SSHHostStore.hosts()
```

Add section after the gitignore section:

```swift
Section("SSH Hosts") {
    ForEach(sshHosts, id: \.self) { host in
        HStack {
            Text(host)
            Spacer()
            Button(role: .destructive) {
                SSHHostStore.remove(host)
                sshHosts = SSHHostStore.hosts()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
    if sshHosts.isEmpty {
        Text("No saved hosts. Add one from the launcher.")
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/ShimProcess.swift Sources/Canopy/StatusBarData.swift Sources/Canopy/StatusBarView.swift Sources/Canopy/SettingsView.swift
git commit -m "Add remote host indicator to window title, status bar, and settings

- Window title shows [hostname] prefix in remote mode
- Status bar shows network icon + hostname
- Settings view allows managing saved SSH hosts"
```

---

### Task 7: End-to-end test

**Files:** None (manual testing)

- [ ] **Step 1: Build and launch**

```bash
xcodegen generate && xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Canopy.app
```

- [ ] **Step 2: Test local mode still works**

1. Select a local directory
2. Ensure SSH Remote toggle is OFF
3. Start session
4. Send a message, verify Claude responds
5. Verify no `claudeProcessWrapper` in settings.json

- [ ] **Step 3: Test remote mode**

1. Return to launcher (Cmd+Shift+N)
2. Select a directory that exists on the remote machine (e.g. `/tmp`)
3. Toggle SSH Remote ON
4. Enter `mbp` as host
5. Start session
6. Send "Say 'hello from remote'"
7. Verify response comes from remote Claude CLI
8. Verify window title shows `[mbp]`
9. Verify status bar shows network icon + `mbp`

- [ ] **Step 4: Verify cleanup**

1. Return to launcher
2. Start a new LOCAL session
3. Check `~/Library/Application Support/Canopy/settings.json`
4. Verify `claudeProcessWrapper` is NOT present

- [ ] **Step 5: Test saved hosts**

1. Go to Preferences
2. Verify `mbp` appears in SSH Hosts list
3. Return to launcher, toggle SSH Remote ON
4. Verify `mbp` appears in recent hosts dropdown

---

### Task 8: Update documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add SSH Remote section to CLAUDE.md**

Add after the Session Management section:

```markdown
## SSH Remote
- Toggle "SSH Remote" in launcher, enter hostname (e.g. `mbp`, `user@server`)
- Uses CC extension's `claudeProcessWrapper` setting with bundled `ssh-claude-wrapper.sh`
- `CANOPY_SSH_HOST` env var passes target to wrapper script
- Remote machine needs: Claude CLI installed + `claude login` done once interactively
- Window title shows `[hostname]`, status bar shows network icon
- Phase 1 limitation: @-mention file listing and open_file don't work (files are remote)
```

- [ ] **Step 2: Update Next Steps (remove SSH remote, add future phases)**

Replace the SSH remote line with:

```markdown
## Next Steps
1. SSH remote Phase 2 — remote file operations via SSH for @-mention support
2. SSH remote Phase 3 — connection management (reconnect, keepalive)
3. SSH remote Phase 4 — Linux remote support (XDG paths)
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document SSH remote feature in CLAUDE.md"
```
