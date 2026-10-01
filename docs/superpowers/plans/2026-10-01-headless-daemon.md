# Headless daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Canopy --daemon` stops registering with LaunchServices as a second `sh.saqoo.Canopy` app, and launchd (not the GUI) is what starts a registered daemon (issue #279).

**Architecture:** The daemon drops `NSApplication` and runs `RunLoop.main` itself; nothing else about the bundle changes. `DaemonSupervisor` gains a `.kickstart` action: a registered agent is started by `launchctl kickstart`, and a direct start (unregistered Debug, approval pending, or launchd failing) goes through `Process` instead of `NSWorkspace.openApplication`.

**Tech Stack:** Swift 6 / AppKit / ServiceManagement / launchd. Logic tests live in `_SidebarLogicProbe.swift` (DEBUG build, `CANOPY_RUN_LOGIC_PROBE=1`).

**Spec:** `docs/superpowers/specs/2026-10-01-headless-daemon-design.md`

## Global Constraints

- Bundle layout, `Resources/LaunchAgents/*.plist`, signing and bundle ids do not change.
- No `NSApplication.shared` / `NSApp.run` in the daemon process. Any `NSApp` read on a daemon path must tolerate `NSApp == nil`.
- `RunLoop.main` must keep running timers (`Timer.scheduledTimer`, default mode); do not use `dispatchMain()`.
- Do not commit or push; Saqoosha says when. Stage nothing outside this worktree.
- Interactive builds use `./scripts/build_debug_stable.sh`. The installed Release (`/Applications/Canopy.app`) hosts this very session: never quit it, never `launchctl kickstart -k` / `bootout` the `sh.saqoo.Canopy.daemon` label, never kill a pid without `ps -p <pid> -o command=` first.

## Review Focus

- A Release whose agent was registered but whose launchd job exited 0 (today's state on both Macs): the GUI must bring the daemon back under launchd, not start an unmanaged one. Pinned by Task 1's probe (`.enabled` → `.kickstart`) and Task 3's on-device check.
- `register()` that lands in `.requiresApproval`: launchd will not run it, so the start must still fall back to a direct launch rather than wait forever. Pinned by Task 1's probe and the post-kickstart fallback in `start()`.
- A turn completes with no UI client attached: `postTaskCompletedNotification` must not crash on `NSApp == nil`. Pinned by Task 2's on-device step.
- SIGTERM from launchd (logout, `launchctl kill`): sessions stop cleanly and the socket file is removed. Pinned by Task 2's on-device step.
- The GUI quits while it is the process that `Process`-launched the daemon: the daemon keeps running. Pinned by Task 3's on-device step.

---

### Task 1: DaemonSupervisor starts a registered daemon through launchd

**Files:**
- Modify: `Sources/Canopy/DaemonSupervisor.swift` (whole file)
- Modify: `Sources/Canopy/DaemonRegistration.swift` (add `label(bundleId:)`)
- Modify: `Sources/Canopy/MirrorPaneView.swift:290-295` (drop `awaitLaunchd:`)
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift:2018-2027` (supervisor assertions)

**Interfaces:**
- Produces: `DaemonSupervisor.Action` = `.none | .register | .kickstart | .launch`; `DaemonSupervisor.action(socketLive:isDebugBuild:registration:) -> Action`; `DaemonSupervisor.ensureRunning() async -> Bool` (no parameters); `DaemonRegistration.label(bundleId:) -> String`.

- [ ] **Step 1: Replace the supervisor probe block with the new rules**

In `_SidebarLogicProbe.swift`, replace the five `daemon supervisor:` records (lines 2018-2027) with:

```swift
            record("daemon supervisor: a live socket needs nothing",
                   DaemonSupervisor.action(socketLive: true, isDebugBuild: false, registration: .notRegistered) == .none)
            record("daemon supervisor: Release registers when not registered",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .notRegistered) == .register
                       && DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .notFound) == .register)
            record("daemon supervisor: Release launches it itself while approval is pending",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .requiresApproval) == .launch)
            record("daemon supervisor: a registered agent is started by launchd, not by the GUI",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .enabled) == .kickstart)
            record("daemon supervisor: a Debug build registered with CANOPY_REGISTER_DAEMON=1 is launchd's too",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: true, registration: .enabled) == .kickstart)
            record("daemon supervisor: an unregistered Debug build launches its own",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: true, registration: .notRegistered) == .launch)
            record("daemon agent: the launchd label is the plist name without .plist",
                   DaemonRegistration.label(bundleId: "sh.saqoo.Canopy") == "sh.saqoo.Canopy.daemon")
```

- [ ] **Step 2: Build and run the probe to see it fail**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -20`
Expected: build FAILS — `.kickstart` is not a member of `DaemonSupervisor.Action`, `label(bundleId:)` does not exist.

- [ ] **Step 3: Add the label helper**

In `DaemonRegistration.swift`, below `plistName(bundleId:)`:

```swift
    /// The launchd label: `Label` in the plist, which `plistName` names after.
    static func label(bundleId: String) -> String { "\(bundleId).daemon" }
```

- [ ] **Step 4: Rewrite `DaemonSupervisor.swift`**

Replace the whole file with:

```swift
import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonSupervisor")

/// Makes sure this build's daemon is serving its socket before a pane attaches.
/// A registered agent is started by launchd; the GUI starts one itself only when
/// nothing is registered (Debug), approval is pending, or launchd did not bring it up.
/// See docs/superpowers/specs/2026-10-01-headless-daemon-design.md.
enum DaemonSupervisor {
    enum Action: Equatable { case none, register, kickstart, launch }

    /// Registration decides, not build type: a Debug build registered with
    /// CANOPY_REGISTER_DAEMON=1 is launchd's too.
    static func action(socketLive: Bool, isDebugBuild: Bool, registration: SMAppService.Status) -> Action {
        if socketLive { return .none }
        switch registration {
        case .enabled: return .kickstart
        case .notRegistered, .notFound: return isDebugBuild ? .launch : .register
        default: return .launch
        }
    }

    /// One start at a time: every restored pane asks at launch.
    @MainActor private static var inFlight: Task<Bool, Never>?

    /// True once the socket answers.
    @MainActor
    static func ensureRunning() async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in await start() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    @MainActor
    private static func start() async -> Bool {
        let path = DaemonPaths.current
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let bundleId = Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"
        switch action(socketLive: DaemonPaths.socketIsLive(path: path), isDebugBuild: isDebug,
                      registration: DaemonRegistration.status()) {
        case .none:
            return true
        case .register:
            // RunAtLoad starts it; a launch here as well would race launchd's for the socket.
            DaemonRegistration.ensureRegistered()
            if DaemonRegistration.status() == .enabled, await waitForSocket(path, seconds: 15) { return true }
        case .kickstart:
            // A job that exited 0 (a quit, or losing the socket race) is not restarted by KeepAlive.
            kickstart(label: DaemonRegistration.label(bundleId: bundleId))
            if await waitForSocket(path, seconds: 15) { return true }
            logger.notice("launchd did not bring the daemon up within 15 s; starting it directly")
        case .launch:
            break
        }
        launch()
        if await waitForSocket(path, seconds: 10) { return true }
        logger.error("daemon socket did not come up within 10 s")
        return false
    }

    @MainActor
    private static func waitForSocket(_ path: String, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 5) {
            if DaemonPaths.socketIsLive(path: path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Without `-k`: a running job is left alone, a stopped one is started.
    private static func kickstart(label: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            logger.notice("asked launchd to start \(label, privacy: .public)")
        } catch {
            logger.error("launchctl kickstart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A plain child process, not `NSWorkspace.openApplication`: that registers the daemon with
    /// LaunchServices as a second instance of this app (issue #279). Not waited on; it outlives this GUI.
    private static func launch() {
        guard let executable = Bundle.main.executableURL else {
            logger.error("daemon launch failed: no executable URL")
            return
        }
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["--daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            logger.notice("launching a daemon for this build (pid \(proc.processIdentifier))")
        } catch {
            logger.error("daemon launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 5: Update the MirrorPaneView call site**

In `MirrorPaneView.swift`, replace

```swift
                    // Only a restart the daemon announced re-attaches on its own: any other drop
                    // may be a stop made elsewhere, which must not be undone. launchd starts the
                    // new build; `ensureRunning` waits for it before starting one itself.
                    if isDaemon, bridge?.expectsRestart == true {
                        Task { @MainActor [weak session] in
                            guard await DaemonSupervisor.ensureRunning(awaitLaunchd: true), let session,
```

with

```swift
                    // Only a restart the daemon announced re-attaches on its own: any other drop
                    // may be a stop made elsewhere, which must not be undone. launchd starts the
                    // new build; `ensureRunning` asks launchd before starting one itself.
                    if isDaemon, bridge?.expectsRestart == true {
                        Task { @MainActor [weak session] in
                            guard await DaemonSupervisor.ensureRunning(), let session,
```

Then confirm nothing else passes the old argument: `grep -rn "awaitLaunchd\|restartAnnouncedAt" Sources/` → no output.

- [ ] **Step 6: Build and run the probe**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | grep -E "daemon supervisor|daemon agent: the launchd label|^--- "`
Expected: every `daemon supervisor:` line and the label line PASS; summary shows 0 failed.

- [ ] **Step 7: Mutation check**

Temporarily change `case .enabled: return .kickstart` to `return .launch`; rebuild and rerun the probe. Expected: the two `.kickstart` records FAIL. Revert with the editor (not `git checkout` — this repo is jj-colocated; see CLAUDE.md), rebuild, confirm green.

---

### Task 2: The daemon runs without NSApplication

**Files:**
- Modify: `Sources/Canopy/CanopyDaemon.swift:13-49` (`run`, termination handler), `:51` (class declaration), `:104` (`applicationDidFinishLaunching` → `start`), `:293-295` (`applicationWillTerminate`)
- Modify: `Sources/Canopy/ShimProcess.swift:8055` (`NSApp.isActive`)
- Modify: `docs/superpowers/specs/2026-09-29-canopy-server-design.md:44` (the "accessory アプリ" claim)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `DaemonDelegate.start()` (was `applicationDidFinishLaunching(_:)`), `DaemonDelegate.shutDown()` made internal (no longer `private`) so the SIGTERM handler can reach it.

- [ ] **Step 1: Rewrite `CanopyDaemon.run()` and the SIGTERM handler**

In `CanopyDaemon.swift`, replace from `        let app = NSApplication.shared` through the end of `installTerminationHandler()` with:

```swift
        // No NSApplication: one would register this process with LaunchServices as a second
        // instance of the app, which the Dock, Sparkle and `open` then treat as Canopy itself (#279).
        let delegate = DaemonDelegate()
        self.delegate = delegate
        installTerminationHandler(delegate)
        delegate.start()
        // RunLoop, not dispatchMain(): the daemon's timers are scheduled on it. One pool per
        // pass replaces the one NSApplication wrapped around each event.
        while true {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
        }
    }
}

private nonisolated(unsafe) var terminationSource: DispatchSourceSignal?

/// launchd's SIGTERM stops the sessions and removes the socket file; left at its default it ends
/// the process with the socket file behind.
private nonisolated func installTerminationHandler(_ delegate: DaemonDelegate) {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { [weak delegate] in
        MainActor.assumeIsolated {
            delegate?.shutDown()
            exit(0)
        }
    }
    source.resume()
    terminationSource = source
}
```

(The `let app = NSApplication.shared`, `app.setActivationPolicy(.accessory)`, `installTerminationHandler()`, `app.delegate = delegate` and `app.run()` lines are all gone.)

- [ ] **Step 2: Detach `DaemonDelegate` from AppKit**

- `final class DaemonDelegate: NSObject, NSApplicationDelegate {` → `final class DaemonDelegate {`
- `func applicationDidFinishLaunching(_ notification: Notification) {` → `func start() {`
- Delete `func applicationWillTerminate(_ notification: Notification) { shutDown() }` (3 lines).
- `private func shutDown() {` → `func shutDown() {`

Then: `grep -n "NSApp\|NSApplication" Sources/Canopy/CanopyDaemon.swift` → only comments.

- [ ] **Step 3: Make the completion banner safe without NSApp**

In `ShimProcess.swift`, replace

```swift
        guard !NSApp.isActive else { return }
        SessionNotifier.post(title: "Canopy", body: body)
```

with

```swift
        // `NSApp` is nil in the daemon (no NSApplication, #279), where no window can be frontmost.
        if let app = NSApp, app.isActive { return }
        SessionNotifier.post(title: "Canopy", body: body)
```

- [ ] **Step 4: Correct the 2026-09-29 spec in place**

In `docs/superpowers/specs/2026-09-29-canopy-server-design.md` line 44, replace `を、window を出さない accessory アプリとして起動する。` with `を、NSApplication を作らないプロセスとして起動する（2026-10-01 の [headless daemon](2026-10-01-headless-daemon-design.md) で accessory アプリから変更）。`

- [ ] **Step 5: Build and run the probe**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -3`
Expected: build succeeds, summary shows 0 failed.

- [ ] **Step 6: On-device: the Debug daemon is not a LaunchServices app**

The Debug build has its own bundle id (`sh.saqoo.Canopy.debug`), socket and label, so none of this touches the installed Release.

```bash
APP=build/Build/Products/Debug/Canopy.app
"$APP/Contents/MacOS/Canopy" --daemon >/dev/null 2>&1 &
DP=$!; sleep 3; ps -p $DP -o pid,command=
lsappinfo list | grep -c 'bundleID="sh.saqoo.Canopy.debug"'
```

Expected: the daemon pid is alive; the `lsappinfo` count is `0`.

- [ ] **Step 7: On-device: the GUI opens beside it, and a turn finishing with no client does not crash**

```bash
open -n build/Build/Products/Debug/Canopy.app
```

In the Debug GUI, open a new local session in a scratch directory, send `say ok`, wait for the reply, then Cmd+Q the Debug GUI. Expected: `lsappinfo list | grep -c 'bundleID="sh.saqoo.Canopy.debug"'` is `1` while the GUI is up and `0` after it quits; `ps -p $DP` still shows the daemon. Re-open the Debug GUI from Finder (double-click `build/Build/Products/Debug/Canopy.app`): it opens a window. Then, with the Debug GUI quit, inject one more turn by reopening, sending `say ok again`, and quitting before the reply lands. Expected: `ps -p $DP` still alive and `/usr/bin/log show --last 5m --predicate "processID == $DP" --style compact | grep -iE "crash|fatal|NSApp"` empty. Record whether a notification banner appeared (spec: if none, file it as a finding, do not fix here).

- [ ] **Step 8: On-device: SIGTERM shuts down cleanly**

```bash
ps -p $DP -o command= | grep -q -- "Debug/Canopy.app/Contents/MacOS/Canopy --daemon" && kill -TERM $DP; sleep 2
ps -p $DP >/dev/null && echo STILL-RUNNING || echo exited
ls -la "$HOME/Library/Application Support/Canopy/" | grep "daemon-sh.saqoo.Canopy.debug" || echo "socket file removed"
```

Expected: `exited`, `socket file removed`.

---

### Task 3: On-device check of the supervisor paths (Debug, registered)

**Files:** none (verification only; findings go to the PR description).

**Interfaces:**
- Consumes: Task 1's `.kickstart` path and Task 2's headless daemon.

- [ ] **Step 1: Register the Debug agent and reproduce "registered but exited 0"**

```bash
APP=$PWD/build/Build/Products/Debug/Canopy.app
open -n "$APP" --env CANOPY_REGISTER_DAEMON=1
sleep 8; launchctl print gui/$(id -u)/sh.saqoo.Canopy.debug.daemon | grep -E "state =|pid ="
```

Expected: `state = running` and a pid. Then quit the Debug GUI (Cmd+Q) and stop the job the way a quit used to: `launchctl kill TERM gui/$(id -u)/sh.saqoo.Canopy.debug.daemon` (exits 0 via the SIGTERM handler, so KeepAlive leaves it stopped). Confirm `state = not running`.

- [ ] **Step 2: The GUI brings it back under launchd**

```bash
open -n "$APP"; sleep 8
launchctl print gui/$(id -u)/sh.saqoo.Canopy.debug.daemon | grep -E "state =|pid ="
/usr/bin/log show --last 1m --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "DaemonSupervisor"' --style compact | tail -3
```

Expected: `state = running`; the log says `asked launchd to start sh.saqoo.Canopy.debug.daemon` and NOT `launching a daemon for this build`. This settles the spec's open question (kickstart revives an exit-0 job).

- [ ] **Step 3: The daemon outlives the GUI and the Dock shows no tile**

Quit the Debug GUI. Expected: `launchctl print …` still `state = running`; no Dock tile for the Debug Canopy (Saqoosha eyeballs the Dock; do not screenshot the full screen). Double-click the Debug app in Finder: a window opens.

- [ ] **Step 4: Clean up the Debug registration**

```bash
"$APP/Contents/MacOS/Canopy" --unregister-daemon
launchctl print gui/$(id -u)/sh.saqoo.Canopy.debug.daemon 2>&1 | head -1
```

Expected: `daemon agent unregistered`; the print reports the service is not found. Quit any Debug GUI left open. Check `ps -eo pid,command | grep "Debug/Canopy.app"` is empty; for any survivor, verify with `ps -p <pid> -o command=` before `kill`.

- [ ] **Step 5: Raise the CI floor**

Read the probe's `--- N passed` count from Task 2 Step 5's run and set `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` (currently 1738) to that number. Task 1 adds 2 records net (7 replace 5).
