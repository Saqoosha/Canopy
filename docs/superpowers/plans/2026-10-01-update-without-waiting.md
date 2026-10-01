# Updates That Do Not Wait Forever Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daemon update no longer waits on remote viewers that can re-attach, the GUI shows what holds an update and offers Restart now, and sessions on an older extension are listed with a per-session restart.

**Architecture:** Three phases, each its own PR.
- Phase A adds an attach capability (`"restart": true`), narrows `ShimProcess.upgradeBlocker`, and makes a remote Mac pane wait for the remote listener before re-attaching.
- Phase B turns the daemon's upgrade check into an `UpgradeState` value, pushes it to control subscribers as `upgrade_state`, and adds a local-only `restart_now` verb plus a sidebar footer row.
- Phase C records each shim's extension version and adds stale-extension rows to the same value and popover.
Every rule that can be pure is a static function the logic probe reaches.

**Tech Stack:** Swift 6 / SwiftUI / Network.framework, NDJSON over the mirror socket, `_SidebarLogicProbe.swift` for tests.

**Spec:** `docs/superpowers/specs/2026-10-01-update-without-waiting-design.md`

## Global Constraints

- An old client (no `"restart": true`) must keep blocking the restart exactly as today.
- `restart_now` is accepted from local (Unix-socket) control clients only, and refused when no build is pending or the daemon is not under launchd.
- A refused `restart_now` replies with an error and never exits.
- No dark mode: no `prefers-color-scheme`, no dual palette.
- Raise `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` by exactly the number of `record(` calls each task adds. Main is currently at 1761, but read the floor in the worktree rather than trusting that number.
- Build: `./scripts/build_debug_stable.sh`. Probe: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`. Its last line is `--- N passed, M failed`.

## Review Focus

1. **The remote Mac is gone for good, not restarting** (lid closed mid-swap). The pane must fall back to today's `.reconnectFailed` with Retry within the budget, not spin forever. Pinned by `RestartReattach.attempts` in Task 3.
2. **The user presses Retry or closes the pane during the wait loop.** The loop must stop and not re-attach behind them. Task 3's loop checks `connection.status` on every pass.
3. **Restart now is pressed when the daemon was not started by launchd** (a Debug daemon launched directly). The daemon must refuse, not exit with nothing to restart it. Pinned by `restartNowRefusal` in Task 4.
4. **An `upgrade_state` arrives for a build the GUI is already running**, for example because the GUI relaunched first. `pendingBuild == nil` must hide the row. Pinned by `UpgradeState.isEmpty` in Task 4.
5. **An extension folder whose `package.json` is unreadable.** The shim's version is nil and must not be listed as stale against every installed version. Pinned in Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Canopy/MirrorSink.swift` | `reattachesAfterRestart` on the sink protocol |
| `Sources/Canopy/MirrorServer.swift` | parse `restart` on attach; `announceRestart` unchanged |
| `Sources/Canopy/MirrorClient.swift` | send `"restart": true` |
| `Sources/Canopy/ShimProcess.swift` | `remoteClientBlocksUpgrade`, `extensionVersion` |
| `Sources/Canopy/RestartReattach.swift` (new) | budget math and the TCP listener probe for a remote pane |
| `Sources/Canopy/MirrorPaneView.swift` | the wait-then-re-attach loop |
| `Sources/Canopy/ConnectionState.swift` | `.awaitingRestart` status and its message |
| `Sources/Canopy/DaemonUpgrade.swift` | `UpgradeState`, `Hold`, `ExtensionState`, wire, `restartNowRefusal` |
| `Sources/Canopy/DaemonUpgradeCenter.swift` (new) | daemon-side observable state plus the restart hook |
| `Sources/Canopy/CanopyDaemon.swift` | compute and publish state; restart path shared with `restart_now` |
| `Sources/Canopy/ControlSession.swift` | push `upgrade_state`; `restart_now` verb |
| `Sources/Canopy/ControlClient.swift` | decode `upgrade_state` |
| `Sources/Canopy/PendingUpdate.swift` (new) | GUI-side observable value plus the footer row and popover |
| `Sources/Canopy/SidebarAccountSection.swift` | mount the row |
| `Sources/Canopy/CanopyApp.swift` | wire `onUpgradeState` |
| `Sources/Canopy/CCExtension.swift` | `version(at:)` |
| `Sources/Canopy/_SidebarLogicProbe.swift` | assertions |

---

# Phase A — remote clients re-attach (PR 1)

### Task 1: The `restart` capability and the narrowed blocker

**Files:**
- Modify: `Sources/Canopy/MirrorSink.swift` (protocol plus a default extension)
- Modify: `Sources/Canopy/MirrorServer.swift` (the `MirrorConnection` attach handler, near `fetchesImages = …`)
- Modify: `Sources/Canopy/MirrorClient.swift:207` (the attach dictionary)
- Modify: `Sources/Canopy/ShimProcess.swift:121` (the `upgradeBlocker` remote clause)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift` (new MARK block after `// MARK: - Mirror session list (#282)`'s block)

**Interfaces:**
- Produces:
  - `MirrorSink.reattachesAfterRestart: Bool`, with a default of `false`.
  - `static func ShimProcess.remoteClientBlocksUpgrade(isLocal: Bool, reattaches: Bool) -> Bool`.
  - `static func MirrorConnection.reattachesAfterRestart(attach: [String: Any]) -> Bool`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
        // MARK: - Remote clients that re-attach do not hold an upgrade
        record("upgrade blocker: a local pane never holds an upgrade",
               !ShimProcess.remoteClientBlocksUpgrade(isLocal: true, reattaches: false))
        record("upgrade blocker: a remote client that re-attaches by itself does not hold it",
               !ShimProcess.remoteClientBlocksUpgrade(isLocal: false, reattaches: true))
        record("upgrade blocker: an older remote client still holds it",
               ShimProcess.remoteClientBlocksUpgrade(isLocal: false, reattaches: false))
        record("attach: restart capability is read only from a literal true",
               MirrorConnection.reattachesAfterRestart(attach: ["restart": true])
                   && !MirrorConnection.reattachesAfterRestart(attach: ["restart": "true"])
                   && !MirrorConnection.reattachesAfterRestart(attach: [:]))
```

- [ ] **Step 2: Build to verify it fails**

Run: `./scripts/build_debug_stable.sh 2>&1 | grep -E "error:|BUILD" | head`
Expected: errors naming `remoteClientBlocksUpgrade` and `reattachesAfterRestart`.

- [ ] **Step 3: Implement**

In `MirrorSink.swift`, add to the protocol:

```swift
    /// Whether this client said at attach (`"restart": true`) that it re-attaches by
    /// itself after a `daemon_restarting` notice, so a daemon upgrade need not wait for it.
    var reattachesAfterRestart: Bool { get }
```

Then add a default in the protocol's extension, creating one if none exists:

```swift
extension MirrorSink {
    var reattachesAfterRestart: Bool { false }
}
```

In `MirrorServer.swift`, `MirrorConnection`, beside `fetchesImages`:

```swift
    /// Set from the attach's `"restart": true`; see `MirrorSink.reattachesAfterRestart`.
    private(set) var reattachesAfterRestart = false

    nonisolated static func reattachesAfterRestart(attach dict: [String: Any]) -> Bool {
        dict["restart"] as? Bool == true
    }
```

In the attach handler, after `fetchesImages = …`:

```swift
        reattachesAfterRestart = Self.reattachesAfterRestart(attach: dict)
```

In `MirrorClient.swift`, add `"restart": true,` to the attach dictionary, after `"usage": true,`.

In `ShimProcess.swift`, replace the remote clause in `upgradeBlocker`:

```swift
        if mirrors.values.contains(where: { client in
            client.sink.map { Self.remoteClientBlocksUpgrade(isLocal: $0.isLocalClient, reattaches: $0.reattachesAfterRestart) } ?? false
        }) {
            return "a phone or another Mac without automatic reconnect is attached"
        }
```

Add near `upgradeBlocker`:

```swift
    /// A remote client holds an upgrade only when it will not re-attach by itself;
    /// a local pane always re-attaches (`MirrorPaneView`'s `isDaemon` branch).
    nonisolated static func remoteClientBlocksUpgrade(isLocal: Bool, reattaches: Bool) -> Bool {
        !isLocal && !reattaches
    }
```

- [ ] **Step 4: Build, run the probe, raise the floor**

Run: `./scripts/build_debug_stable.sh 2>&1 | tail -1 && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1`
Expected: `--- N passed, 0 failed`. Then set `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` to N.

- [ ] **Step 5: Commit**

```bash
git add Sources/Canopy/MirrorSink.swift Sources/Canopy/MirrorServer.swift Sources/Canopy/MirrorClient.swift Sources/Canopy/ShimProcess.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Let remote clients that re-attach stop holding daemon upgrades"
```

### Task 2: Measure the restart gap that sets the budget

This task is a measurement, not code. Task 3's numbers come from it.

- [ ] **Step 1: Time the daemon's TCP listener coming back**

Run this against this Mac's Release daemon. It costs a restart of its sessions, which resume from their transcripts, so ask Saqoosha first.

```bash
PORT=$(defaults read sh.saqoo.Canopy canopy.mirrorPort 2>/dev/null || echo 8766)
date +%s.%N; launchctl kickstart -k gui/$(id -u)/sh.saqoo.Canopy.daemon
until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do sleep 0.2; done; date +%s.%N
```

If `canopy.mirrorPort` is not the right key, find the port with `lsof -nP -iTCP -sTCP:LISTEN | grep Canopy` before running this.

Expected: two timestamps. The gap is the time from the restart to the listener being reachable.

- [ ] **Step 2: Record the number**

Take the measured gap. If it is above 20 s, set `RestartReattach.budget` in Task 3 to three times the gap. Otherwise keep 60 s. Write the measurement into the doc comment on `RestartReattach.budget`.

### Task 3: A remote pane waits for the listener, then re-attaches

**Files:**
- Create: `Sources/Canopy/RestartReattach.swift`
- Modify: `Sources/Canopy/ConnectionState.swift`
- Modify: `Sources/Canopy/MirrorPaneView.swift` (the `.dropped` branch at `if isDaemon, bridge?.expectsRestart == true`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `MirrorClient.expectsRestart` (existing), and `SessionStore.restartSession(_:notifyDaemon:)` (existing).
- Produces:
  - `enum RestartReattach { static let interval: TimeInterval; static let budget: TimeInterval; static func attempts(interval:budget:) -> Int; static func listenerIsUp(host: String, port: UInt16, timeout: TimeInterval) async -> Bool }`.
  - `ConnectionStatus.awaitingRestart(machine: String)`.

Why it waits for the listener first: `restartSession` puts the pane back in `.spawning`, and a connection failure in `.spawning` closes the pane through `onFailure`. Re-attaching before the listener is up would therefore close the pane rather than retry.

- [ ] **Step 1: Write the failing assertions**

```swift
        // MARK: - Remote pane re-attach after a daemon restart
        record("restart re-attach: the budget is spent in whole intervals",
               RestartReattach.attempts(interval: 2, budget: 60) == 30
                   && RestartReattach.attempts(interval: 2, budget: 61) == 30)
        record("restart re-attach: a budget shorter than one interval still tries once",
               RestartReattach.attempts(interval: 2, budget: 1) == 1)
        record("restart re-attach: the overlay names the machine",
               { let s = ConnectionState(); s.status = .awaitingRestart(machine: "studio")
                 return s.isOverlayVisible && s.statusMessage == "studio is restarting for an update. Reconnecting…" }())
```

- [ ] **Step 2: Build to verify it fails**

Run: `./scripts/build_debug_stable.sh 2>&1 | grep -E "error:" | head`
Expected: errors naming `RestartReattach` and `awaitingRestart`.

- [ ] **Step 3: Implement `RestartReattach.swift`**

```swift
import Foundation
import Network

/// How a mirror pane on another Mac gets back to a session after that Mac's daemon
/// announced `daemon_restarting`. The pane waits for the listener before re-attaching:
/// `restartSession` puts it back in `.spawning`, where a failed connection closes it.
enum RestartReattach {
    static let interval: TimeInterval = 2
    /// Measured in Task 2 of docs/superpowers/plans/2026-10-01-update-without-waiting.md; replace this line with the figure.
    static let budget: TimeInterval = 60

    nonisolated static func attempts(interval: TimeInterval, budget: TimeInterval) -> Int {
        max(1, Int(budget / interval))
    }

    /// True when a TCP connection to the listener becomes ready within `timeout`.
    nonisolated static func listenerIsUp(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "sh.saqoo.Canopy.RestartReattach")
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            @Sendable func finish(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
```

`.waiting` counts as down because a refused connection lands there. The next pass of the loop tries again.

- [ ] **Step 4: Add the status**

In `ConnectionState.swift`, add the case `case awaitingRestart(machine: String)` to `ConnectionStatus`. Add this arm to `statusMessage`:

```swift
        case .awaitingRestart(let machine):
            return "\(machine) is restarting for an update. Reconnecting…"
```

- [ ] **Step 5: The loop in `MirrorPaneView`**

Replace the `if isDaemon, bridge?.expectsRestart == true { … }` block with:

```swift
                    if bridge?.expectsRestart == true {
                        if isDaemon {
                            Task { @MainActor [weak session] in
                                guard await DaemonSupervisor.ensureRunning(), let session,
                                      session.connection.status == .reconnectFailed else { return }
                                logger.notice("[mirror-pane] session service restarted; re-attaching \(session.resumeId, privacy: .public)")
                                SessionStore.shared?.restartSession(session.id, notifyDaemon: false)
                            }
                        } else if let target = session.origin.mirrorTarget {
                            let waiting = ConnectionStatus.awaitingRestart(machine: machineName)
                            session.connection.status = waiting
                            Task { @MainActor [weak session] in
                                for _ in 0..<RestartReattach.attempts(interval: RestartReattach.interval, budget: RestartReattach.budget) {
                                    guard let current = session, current.connection.status == waiting else { return }
                                    if await RestartReattach.listenerIsUp(host: target.host, port: target.port, timeout: RestartReattach.interval) {
                                        guard let current = session, current.connection.status == waiting else { return }
                                        logger.notice("[mirror-pane] \(machineName, privacy: .public) is back; re-attaching \(current.resumeId, privacy: .public)")
                                        SessionStore.shared?.restartSession(current.id, notifyDaemon: false)
                                        return
                                    }
                                    try? await Task.sleep(for: .seconds(RestartReattach.interval))
                                }
                                guard let current = session, current.connection.status == waiting else { return }
                                logger.notice("[mirror-pane] \(machineName, privacy: .public) did not come back within \(Int(RestartReattach.budget))s")
                                current.connection.status = .reconnectFailed
                            }
                        }
                    }
```

Retry sets `.connected` through `restartSession`, and closing the pane releases `session`. Either one ends the loop on its next check. Read `mirrorTarget`'s property names off `OpenSession.swift` before using `target.host` / `target.port`; the plan assumes those names.

- [ ] **Step 6: Build, probe, raise the floor**

Same commands as Task 1, Step 4. Expected: `0 failed`.

- [ ] **Step 7: On-device check (studio → this Mac)**

Open a session from this Mac in a pane on studio. Upgrading needs a new build, so stand in for the swap with `launchctl kickstart -k gui/$(id -u)/sh.saqoo.Canopy.daemon` on this Mac. A kickstart sends no `daemon_restarting`, though, so this checks only the Retry path. The real check is the next release: the studio pane shows "… is restarting for an update. Reconnecting…" and comes back on its own. Record which of the two was done in the PR body.

- [ ] **Step 8: Commit**

```bash
git add Sources/Canopy/RestartReattach.swift Sources/Canopy/ConnectionState.swift Sources/Canopy/MirrorPaneView.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Re-attach a remote mirror pane after its daemon restarts for an update"
```

`RestartReattach.swift` is a new file. `project.yml` globs `Sources/Canopy`, so `xcodegen generate` (which `build_debug_stable.sh` runs) picks it up.

---

# Phase B — pending update in the GUI (PR 2)

### Task 4: `UpgradeState` and its rules

**Files:**
- Modify: `Sources/Canopy/DaemonUpgrade.swift`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:

```swift
struct UpgradeHold: Equatable { let key: String; let title: String; let reason: String }
struct StaleExtensionSession: Equatable { let key: String; let title: String; let running: String; let blocker: String? }
struct ExtensionUpgradeState: Equatable { let installed: String; let stale: [StaleExtensionSession] }
struct UpgradeState: Equatable {
    var runningBuild: String
    var pendingBuild: String?
    var heldBy: [UpgradeHold]
    var notUnderLaunchd: Bool
    var extensionState: ExtensionUpgradeState?
    var isEmpty: Bool              // no pending build and no stale extension
    var wire: [String: Any]
    init?(wire: [String: Any])
}
extension DaemonUpgrade {
    static func restartNowRefusal(pendingBuild: String?, underLaunchd: Bool) -> String?
}
```

- [ ] **Step 1: Write the failing assertions**

```swift
        // MARK: - Upgrade state for the GUI
        do {
            let hold = UpgradeHold(key: "k1", title: "Fix CI", reason: "a turn, question or background task is running")
            let stale = StaleExtensionSession(key: "k2", title: "Docs", running: "2.1.286", blocker: nil)
            let full = UpgradeState(runningBuild: "149", pendingBuild: "150", heldBy: [hold], notUnderLaunchd: false,
                                    extensionState: ExtensionUpgradeState(installed: "2.1.290", stale: [stale]))
            record("upgrade state: survives the wire unchanged", UpgradeState(wire: full.wire) == full)
            let none = UpgradeState(runningBuild: "150", pendingBuild: nil, heldBy: [], notUnderLaunchd: false, extensionState: nil)
            record("upgrade state: no pending build and no stale extension is empty", none.isEmpty && UpgradeState(wire: none.wire) == none)
            record("upgrade state: an extension with no stale sessions is still empty",
                   UpgradeState(runningBuild: "150", pendingBuild: nil, heldBy: [], notUnderLaunchd: false,
                                extensionState: ExtensionUpgradeState(installed: "2.1.290", stale: [])).isEmpty)
            record("upgrade state: a stale extension alone is not empty",
                   !UpgradeState(runningBuild: "150", pendingBuild: nil, heldBy: [], notUnderLaunchd: false,
                                 extensionState: ExtensionUpgradeState(installed: "2.1.290", stale: [stale])).isEmpty)
            record("upgrade state: an unreadable wire value is nil, not an empty state",
                   UpgradeState(wire: ["heldBy": []]) == nil)
            record("restart now: refused with nothing pending",
                   DaemonUpgrade.restartNowRefusal(pendingBuild: nil, underLaunchd: true) == "no update is waiting")
            record("restart now: refused when launchd would not start the new build",
                   DaemonUpgrade.restartNowRefusal(pendingBuild: "150", underLaunchd: false)
                       == "the session service was not started by launchd, so nothing would start the new build")
            record("restart now: allowed with a pending build under launchd",
                   DaemonUpgrade.restartNowRefusal(pendingBuild: "150", underLaunchd: true) == nil)
        }
```

- [ ] **Step 2: Build to verify it fails**

Expected: errors naming `UpgradeState`, `UpgradeHold` and `restartNowRefusal`.

- [ ] **Step 3: Implement in `DaemonUpgrade.swift`**

```swift
/// One session holding a daemon upgrade, and why (`ShimProcess.upgradeBlocker`).
struct UpgradeHold: Equatable {
    let key: String      // OpenSession.id, as `session_state` keys rows
    let title: String
    let reason: String
}

/// A live shim still on an older extension than the one installed.
struct StaleExtensionSession: Equatable {
    let key: String
    let title: String
    let running: String
    /// Why restarting it now would lose something, or nil.
    let blocker: String?
}

struct ExtensionUpgradeState: Equatable {
    let installed: String
    let stale: [StaleExtensionSession]
}

/// What the daemon tells the GUI about updates it has not applied yet.
struct UpgradeState: Equatable {
    var runningBuild: String
    var pendingBuild: String?
    var heldBy: [UpgradeHold]
    var notUnderLaunchd: Bool
    var extensionState: ExtensionUpgradeState?

    var isEmpty: Bool { pendingBuild == nil && (extensionState?.stale.isEmpty ?? true) }

    var wire: [String: Any] {
        var dict: [String: Any] = [
            "runningBuild": runningBuild,
            "heldBy": heldBy.map { ["key": $0.key, "title": $0.title, "reason": $0.reason] },
            "notUnderLaunchd": notUnderLaunchd,
        ]
        if let pendingBuild { dict["pendingBuild"] = pendingBuild }
        if let extensionState {
            dict["extension"] = [
                "installed": extensionState.installed,
                "stale": extensionState.stale.map { row -> [String: Any] in
                    var r: [String: Any] = ["key": row.key, "title": row.title, "running": row.running]
                    if let blocker = row.blocker { r["blocker"] = blocker }
                    return r
                },
            ]
        }
        return dict
    }

    init(runningBuild: String, pendingBuild: String?, heldBy: [UpgradeHold], notUnderLaunchd: Bool,
         extensionState: ExtensionUpgradeState?) {
        self.runningBuild = runningBuild
        self.pendingBuild = pendingBuild
        self.heldBy = heldBy
        self.notUnderLaunchd = notUnderLaunchd
        self.extensionState = extensionState
    }

    init?(wire: [String: Any]) {
        guard let running = wire["runningBuild"] as? String,
              let holds = wire["heldBy"] as? [[String: Any]] else { return nil }
        var parsedHolds: [UpgradeHold] = []
        for h in holds {
            guard let key = h["key"] as? String, let title = h["title"] as? String,
                  let reason = h["reason"] as? String else { return nil }
            parsedHolds.append(UpgradeHold(key: key, title: title, reason: reason))
        }
        var ext: ExtensionUpgradeState?
        if let e = wire["extension"] as? [String: Any] {
            guard let installed = e["installed"] as? String, let rows = e["stale"] as? [[String: Any]] else { return nil }
            var stale: [StaleExtensionSession] = []
            for r in rows {
                guard let key = r["key"] as? String, let title = r["title"] as? String,
                      let runningVersion = r["running"] as? String else { return nil }
                stale.append(StaleExtensionSession(key: key, title: title, running: runningVersion,
                                                   blocker: r["blocker"] as? String))
            }
            ext = ExtensionUpgradeState(installed: installed, stale: stale)
        }
        self.init(runningBuild: running, pendingBuild: wire["pendingBuild"] as? String, heldBy: parsedHolds,
                  notUnderLaunchd: wire["notUnderLaunchd"] as? Bool ?? false, extensionState: ext)
    }
}

extension DaemonUpgrade {
    /// Why `restart_now` must not exit, or nil. Without launchd nothing would start the new build.
    static func restartNowRefusal(pendingBuild: String?, underLaunchd: Bool) -> String? {
        guard pendingBuild != nil else { return "no update is waiting" }
        guard underLaunchd else { return "the session service was not started by launchd, so nothing would start the new build" }
        return nil
    }

    /// The frame type control subscribers receive.
    static let stateFrameType = "upgrade_state"
}
```

- [ ] **Step 4: Build, probe, raise the floor.** Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Canopy/DaemonUpgrade.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Describe a waiting daemon upgrade as a value the GUI can read"
```

### Task 5: The daemon publishes the state and accepts `restart_now`

**Files:**
- Create: `Sources/Canopy/DaemonUpgradeCenter.swift`
- Modify: `Sources/Canopy/CanopyDaemon.swift` (`restartIfUpgraded`, around lines 76–107)
- Modify: `Sources/Canopy/ControlSession.swift` (`handle` switch; `subscribe`; `stop`)

**Interfaces:**
- Consumes: `UpgradeState`, `DaemonUpgrade.restartNowRefusal` (Task 4).
- Produces: `@MainActor @Observable final class DaemonUpgradeCenter { static let shared; var state: UpgradeState?; var restartNow: (() -> String?)? }`. `restartNow` returns a refusal message, or nil once it has started the restart.

- [ ] **Step 1: Create `DaemonUpgradeCenter.swift`**

```swift
import Foundation
import Observation

/// The daemon's view of updates it has not applied, for `ControlSession` to push.
/// Written only by `DaemonDelegate`; nil until its first upgrade check.
@MainActor @Observable
final class DaemonUpgradeCenter {
    static let shared = DaemonUpgradeCenter()
    var state: UpgradeState?
    /// Set by `DaemonDelegate`. Returns why it refused, or nil once the restart has begun.
    @ObservationIgnored var restartNow: (() -> String?)?
}
```

- [ ] **Step 2: Rework `restartIfUpgraded` to collect every hold and publish**

Replace the body of `restartIfUpgraded()` with:

```swift
    private func restartIfUpgraded() {
        let onDisk = DaemonUpgrade.onDiskBuild()
        defer { previousOnDiskBuild = onDisk }
        let underLaunchd = DaemonUpgrade.isUnderLaunchd(env: ProcessInfo.processInfo.environment,
                                                        bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        let pending = onDisk.flatMap { $0 != DaemonUpgrade.launchedBuild ? $0 : nil }
        // Transcript lookups in `upgradeBlocker` can scan the store, so holds are read only while a build waits.
        let holds: [UpgradeHold] = pending == nil ? [] : store.openSessions.compactMap { session in
            session.shim?.upgradeBlocker.map { UpgradeHold(key: session.id.uuidString, title: session.title, reason: $0) }
        }
        publishUpgradeState(pending: pending, holds: holds, underLaunchd: underLaunchd)
        guard let onDisk, DaemonUpgrade.shouldRestart(launchedBuild: DaemonUpgrade.launchedBuild, onDiskBuild: onDisk,
                                                      previousOnDiskBuild: previousOnDiskBuild,
                                                      underLaunchd: underLaunchd, blocked: !holds.isEmpty) else {
            if let onDisk, pending != nil {
                let hold = !underLaunchd ? "not started by launchd, so nothing would start the new build"
                    : holds.first.map { "\($0.key.prefix(8)): \($0.reason)" } ?? "confirming on the next check"
                if hold != lastUpgradeHold {
                    lastUpgradeHold = hold
                    logger.notice("build \(onDisk, privacy: .public) is installed (running \(DaemonUpgrade.launchedBuild ?? "?", privacy: .public)); waiting: \(hold, privacy: .public)")
                }
            }
            return
        }
        performUpgradeRestart(to: onDisk)
    }

    private func publishUpgradeState(pending: String?, holds: [UpgradeHold], underLaunchd: Bool) {
        let state = UpgradeState(runningBuild: DaemonUpgrade.launchedBuild ?? "?", pendingBuild: pending, heldBy: holds,
                                 notUnderLaunchd: !underLaunchd, extensionState: nil)
        if DaemonUpgradeCenter.shared.state != state { DaemonUpgradeCenter.shared.state = state }
    }

    /// Announce, stop the shims, exit 1 so launchd starts the new build. Shared by the
    /// timer and by `restart_now`, which skips the hold check.
    private func performUpgradeRestart(to build: String) {
        logger.notice("restarting for build \(build, privacy: .public) (running \(DaemonUpgrade.launchedBuild ?? "?", privacy: .public))")
        upgradeTimer?.invalidate()
        configTimer?.invalidate()  // a reload in the next second would re-open the listeners
        server?.announceRestart()
        // Sends are asynchronous: give the notice a moment to leave before the process does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.shutDown()
                exit(1)
            }
        }
    }
```

In `start()`, after the server is created, install the hook:

```swift
        DaemonUpgradeCenter.shared.restartNow = { [weak self] in
            let pending = DaemonUpgradeCenter.shared.state?.pendingBuild
            let underLaunchd = DaemonUpgrade.isUnderLaunchd(env: ProcessInfo.processInfo.environment,
                                                            bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
            if let refusal = DaemonUpgrade.restartNowRefusal(pendingBuild: pending, underLaunchd: underLaunchd) { return refusal }
            guard let self, let pending else { return "the session service is shutting down" }
            logger.notice("restart now requested; interrupting \(DaemonUpgradeCenter.shared.state?.heldBy.count ?? 0) session(s)")
            self.performUpgradeRestart(to: pending)
            return nil
        }
```

- [ ] **Step 3: Push from `ControlSession`**

Add a stored `private var lastUpgradeState: UpgradeState?`. In `subscribe`, after `trackOpenSessions()`, call `trackUpgradeState()`:

```swift
    private func trackUpgradeState() {
        guard !stopped else { return }
        let state = withObservationTracking {
            DaemonUpgradeCenter.shared.state
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackUpgradeState() } }
        }
        guard let state, state != lastUpgradeState else { return }
        lastUpgradeState = state
        send(["type": DaemonUpgrade.stateFrameType, "state": state.wire])
    }
```

Add the verb to the `handle` switch:

```swift
        case "restart_now":
            // Interrupts every running turn on this Mac; only this Mac's GUI may ask.
            guard isLocal else { return fail(request, "local clients only") }
            guard let restart = DaemonUpgradeCenter.shared.restartNow else { return fail(request, "not a daemon") }
            if let refusal = restart() { return fail(request, refusal) }
            reply(request, ["ok": true])
```

The reply goes out before the 1 s exit delay in `performUpgradeRestart`.

- [ ] **Step 4: Build.** `./scripts/build_debug_stable.sh 2>&1 | tail -1` gives `** BUILD SUCCEEDED **`. Run the probe; the count must not drop.

- [ ] **Step 5: Socket check against the Debug daemon**

The Debug daemon is not under launchd, so `restart_now` must refuse. With the Debug app running, use the control socket recipe from the earlier sessions: `hello{protocolVersion:1}`, `subscribe`, then `request{verb:"restart_now"}`.
Expected: an `upgrade_state` line with `"notUnderLaunchd": true`, and the response error `no update is waiting`. A pending build is not faked here.

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/DaemonUpgradeCenter.swift Sources/Canopy/CanopyDaemon.swift Sources/Canopy/ControlSession.swift
git commit -m "Push the waiting upgrade to control clients and add restart_now"
```

### Task 6: GUI footer row, popover and Restart now

**Files:**
- Create: `Sources/Canopy/PendingUpdate.swift`
- Modify: `Sources/Canopy/ControlClient.swift` (frame switch near `case "session_state":`)
- Modify: `Sources/Canopy/CanopyApp.swift:450` (wire `onUpgradeState`)
- Modify: `Sources/Canopy/SidebarAccountSection.swift` (mount the row above the version row)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `UpgradeState` (Task 4), and the `upgrade_state` frame `{"type":"upgrade_state","state":<wire>}` (Task 5).
- Produces:
  - `ControlClient.onUpgradeState: ((UpgradeState) -> Void)?`.
  - `@MainActor @Observable final class PendingUpdate { static let shared; var state: UpgradeState?; var restarting: Bool }`.
  - `static func PendingUpdate.headline(_ state: UpgradeState, restarting: Bool) -> String?`.
  - `static func PendingUpdate.confirmation(_ holds: [UpgradeHold]) -> String`.
  - `struct PendingUpdateRow: View`.

- [ ] **Step 1: Write the failing assertions**

```swift
        // MARK: - Pending update footer
        do {
            let hold = UpgradeHold(key: "k", title: "Fix CI", reason: "a turn, question or background task is running")
            func state(_ pending: String?, _ holds: [UpgradeHold], _ ext: ExtensionUpgradeState? = nil) -> UpgradeState {
                UpgradeState(runningBuild: "149", pendingBuild: pending, heldBy: holds, notUnderLaunchd: false, extensionState: ext)
            }
            record("pending update: nothing pending shows nothing", PendingUpdate.headline(state(nil, []), restarting: false) == nil)
            record("pending update: a held build counts its sessions",
                   PendingUpdate.headline(state("150", [hold, hold]), restarting: false) == "Update ready — waiting for 2 sessions"
                       && PendingUpdate.headline(state("150", [hold]), restarting: false) == "Update ready — waiting for 1 session")
            record("pending update: restarting outranks the count",
                   PendingUpdate.headline(state("150", [hold]), restarting: true) == "Update ready — restarting…")
            let ext = ExtensionUpgradeState(installed: "2.1.290",
                                            stale: [StaleExtensionSession(key: "a", title: "A", running: "2.1.286", blocker: nil)])
            record("pending update: a stale extension alone gets its own line",
                   PendingUpdate.headline(state(nil, [], ext), restarting: false) == "Extension 2.1.290 — 1 session on an older version")
            record("pending update: confirmation names what is interrupted",
                   PendingUpdate.confirmation([hold])
                       == "1 session is busy: Fix CI. Restarting stops its current work. Conversations are kept.")
        }
```

- [ ] **Step 2: Build to verify it fails.** Expected: errors naming `PendingUpdate`.

- [ ] **Step 3: Implement `PendingUpdate.swift`**

```swift
import SwiftUI
import Observation

/// The daemon's waiting updates as the GUI sees them (`upgrade_state`).
@MainActor @Observable
final class PendingUpdate {
    static let shared = PendingUpdate()
    var state: UpgradeState?
    /// From Restart now until the control connection comes back on the new daemon.
    var restarting = false

    nonisolated static func headline(_ state: UpgradeState, restarting: Bool) -> String? {
        if state.pendingBuild != nil {
            if restarting { return "Update ready — restarting…" }
            if !state.heldBy.isEmpty {
                let n = state.heldBy.count
                return "Update ready — waiting for \(n) session\(n == 1 ? "" : "s")"
            }
            return "Update ready — restarting…"
        }
        if let ext = state.extensionState, !ext.stale.isEmpty {
            let n = ext.stale.count
            return "Extension \(ext.installed) — \(n) session\(n == 1 ? "" : "s") on an older version"
        }
        return nil
    }

    nonisolated static func confirmation(_ holds: [UpgradeHold]) -> String {
        let n = holds.count
        let names = holds.map(\.title).joined(separator: ", ")
        return "\(n) session\(n == 1 ? " is" : "s are") busy: \(names). Restarting stops \(n == 1 ? "its" : "their") current work. Conversations are kept."
    }
}

/// One line above the version row while an update waits; click for details.
struct PendingUpdateRow: View {
    @State private var shown = false
    private var pending: PendingUpdate { .shared }

    var body: some View {
        if let state = pending.state, let line = PendingUpdate.headline(state, restarting: pending.restarting) {
            Button { shown = true } label: {
                Label(line, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $shown, arrowEdge: .top) { PendingUpdateDetail(state: state) }
        }
    }
}

private struct PendingUpdateDetail: View {
    let state: UpgradeState
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = state.pendingBuild {
                Text("Build \(pending) is installed; the session service runs \(state.runningBuild).").font(.headline)
                ForEach(state.heldBy, id: \.key) { hold in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hold.title).font(.system(size: 12, weight: .medium))
                        Text(hold.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !state.heldBy.isEmpty && !state.notUnderLaunchd {
                    Button("Restart now") { confirmAndRestart() }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .padding(12).frame(width: 320, alignment: .leading)
    }

    private func confirmAndRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart the session service now?"
        alert.informativeText = PendingUpdate.confirmation(state.heldBy)
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn, let control = SessionStore.shared?.daemonControl else { return }
        PendingUpdate.shared.restarting = true
        Task { @MainActor in
            if case .failure(let failure) = await control.request("restart_now", [:]) {
                PendingUpdate.shared.restarting = false
                error = "Could not restart: \(failure)"
            }
        }
    }
}
```

Check `ControlClient.request`'s actual signature and failure type before using `.failure(let failure)`; `SessionStore.restartSession` uses the same shape. `PendingUpdate.headline` already handles a pending build with no holds, but Task 5's daemon restarts on its own in that case, so the popover offers no button there.

- [ ] **Step 4: Decode and wire**

In `ControlClient.swift`, add `var onUpgradeState: ((UpgradeState) -> Void)?` beside `onSessionState`. Add this to the frame switch:

```swift
        case DaemonUpgrade.stateFrameType:
            guard let wire = dict["state"] as? [String: Any], let state = UpgradeState(wire: wire) else {
                logger.error("unreadable upgrade_state from the daemon")
                return
            }
            onUpgradeState?(state)
```

In `CanopyApp.swift` next to `client.onSessionState = …`:

```swift
        client.onUpgradeState = { state in
            PendingUpdate.shared.state = state
            // A state from a daemon running the build it was waiting for means the restart landed.
            if state.pendingBuild == nil { PendingUpdate.shared.restarting = false }
        }
```

In `SidebarAccountSection.swift`, put `PendingUpdateRow()` directly above the version row that holds `MacroPadIndicator()`, in the same `VStack`, with the same leading alignment as its neighbours.

- [ ] **Step 5: Build, probe, raise the floor.** Expected: `0 failed`.

- [ ] **Step 6: On-device check, window-scoped screenshot only**

The real path needs a Release build newer than the installed one, which happens at the next release. Record that the release is where this gets checked: start a turn, install the release, see "Update ready — waiting for 1 session", press Restart now, confirm, and see the session resume. Until then, check the layout by feeding a fixed state: temporarily set `PendingUpdate.shared.state` in a `#if DEBUG` env-gated line (`CANOPY_PENDING_UPDATE_DEMO=1`), screenshot the sidebar by window id, then remove the line before committing.

- [ ] **Step 7: Commit**

```bash
git add Sources/Canopy/PendingUpdate.swift Sources/Canopy/ControlClient.swift Sources/Canopy/CanopyApp.swift Sources/Canopy/SidebarAccountSection.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Show a waiting update in the sidebar and offer Restart now"
```

---

# Phase C — sessions on an older extension (PR 3)

### Task 7: Each shim's extension version, and the stale list

**Files:**
- Modify: `Sources/Canopy/CCExtension.swift` (add `version(at:)`; `extensionVersion()` uses it)
- Modify: `Sources/Canopy/ShimProcess.swift:2836` (record the version where `extensionPath` is resolved)
- Modify: `Sources/Canopy/DaemonUpgrade.swift` (`ExtensionUpgradeState.assemble`)
- Modify: `Sources/Canopy/CanopyDaemon.swift` (`publishUpgradeState` fills `extensionState`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:
  - `static func CCExtension.version(at: URL) -> String?`.
  - `ShimProcess.extensionVersion: String?`, set once at spawn.
  - `static func ExtensionUpgradeState.assemble(installed: String?, sessions: [(key: String, title: String, running: String?, blocker: String?)]) -> ExtensionUpgradeState?`.

- [ ] **Step 1: Write the failing assertions**

```swift
        // MARK: - Sessions on an older extension
        do {
            let rows: [(key: String, title: String, running: String?, blocker: String?)] = [
                ("a", "A", "2.1.290", nil), ("b", "B", "2.1.286", "a turn, question or background task is running"),
                ("c", "C", nil, nil),
            ]
            let state = ExtensionUpgradeState.assemble(installed: "2.1.290", sessions: rows)
            record("stale extension: only a known, different version is listed, with its blocker",
                   state?.stale == [StaleExtensionSession(key: "b", title: "B", running: "2.1.286",
                                                          blocker: "a turn, question or background task is running")])
            record("stale extension: an unreadable installed version yields no state",
                   ExtensionUpgradeState.assemble(installed: nil, sessions: rows) == nil)
        }
```

- [ ] **Step 2: Build to verify it fails.** Expected: an error naming `assemble`.

- [ ] **Step 3: Implement**

In `CCExtension.swift`:

```swift
    /// The `version` in an extension folder's package.json.
    static func version(at extPath: URL) -> String? {
        guard let data = try? Data(contentsOf: extPath.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }
```

Then reduce `extensionVersion()` to `extensionPath().flatMap(version(at:))`.

In `ShimProcess.swift`, add `private(set) var extensionVersion: String?`. At line 2836, after `guard let extensionPath = CCExtension.extensionPath()?.path else { … }`, add:

```swift
        extensionVersion = CCExtension.version(at: URL(fileURLWithPath: extensionPath))
```

In `DaemonUpgrade.swift`:

```swift
extension ExtensionUpgradeState {
    /// Sessions whose shim started on a version other than the one installed. A shim whose
    /// version could not be read is left out: listing it would offer a restart that may change nothing.
    static func assemble(installed: String?,
                         sessions: [(key: String, title: String, running: String?, blocker: String?)]) -> ExtensionUpgradeState? {
        guard let installed else { return nil }
        let stale = sessions.compactMap { row -> StaleExtensionSession? in
            guard let running = row.running, running != installed else { return nil }
            return StaleExtensionSession(key: row.key, title: row.title, running: running, blocker: row.blocker)
        }
        return ExtensionUpgradeState(installed: installed, stale: stale)
    }
}
```

In `CanopyDaemon.publishUpgradeState`, replace `extensionState: nil` with:

```swift
            extensionState: ExtensionUpgradeState.assemble(
                installed: CCExtension.extensionVersion(),
                sessions: store.openSessions.compactMap { session in
                    guard let shim = session.shim, shim.isLive else { return nil }
                    return (session.id.uuidString, session.title, shim.extensionVersion, shim.upgradeBlocker)
                })
```

`upgradeBlocker` is now read on every check, not only while a build waits, and it can scan the store. Read it only for shims whose version differs: compute `shim.extensionVersion != installed` first, and pass `nil` as the blocker otherwise.

- [ ] **Step 4: Build, probe, raise the floor.** Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Canopy/CCExtension.swift Sources/Canopy/ShimProcess.swift Sources/Canopy/DaemonUpgrade.swift Sources/Canopy/CanopyDaemon.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Report sessions still running an older extension"
```

### Task 8: Restart rows in the popover

**Files:**
- Modify: `Sources/Canopy/PendingUpdate.swift` (`PendingUpdateDetail`)

**Interfaces:**
- Consumes: `ExtensionUpgradeState` (Task 7), and `SessionStore.restartSession(_:notifyDaemon:)` (existing; for a daemon-hosted session it sends `restart_session` first).

- [ ] **Step 1: Add the section**

In `PendingUpdateDetail.body`, after the build section:

```swift
            if let ext = state.extensionState, !ext.stale.isEmpty {
                Divider()
                Text("Extension \(ext.installed) is installed.").font(.headline)
                ForEach(ext.stale, id: \.key) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.system(size: 12, weight: .medium))
                            Text(row.blocker.map { "\(row.running) · \($0)" } ?? row.running)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart") { restart(row) }
                    }
                }
            }
```

and:

```swift
    private func restart(_ row: StaleExtensionSession) {
        guard let store = SessionStore.shared,
              let session = store.openSessions.first(where: { $0.daemonKey == row.key }) else {
            error = "That session is not open in this window."
            return
        }
        if let blocker = row.blocker {
            let alert = NSAlert()
            alert.messageText = "Restart \(row.title)?"
            alert.informativeText = "It is busy: \(blocker). Restarting stops its current work. The conversation is kept."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.restartSession(session.id)
    }
```

`row.key` is the daemon's `OpenSession.id`, which the GUI stores as `daemonKey`. Confirm that in `applyDaemonSessions` before relying on it.

- [ ] **Step 2: Build, and run the probe so the count is unchanged**

- [ ] **Step 3: On-device check**

With two sessions open, copy the newest extension folder to a higher version number. The canary from #288 is skipped by this copy, so do it by hand: `cp -Rc` the folder to `…-2.1.999-darwin-arm64` and set `"version": "2.1.999"` in its `package.json`. Within one upgrade-check interval, both sessions are listed. Restart one: its row disappears and the session shows its history. Then delete the fake folder, and restart the remaining session so nothing runs from it.

- [ ] **Step 4: Commit**

```bash
git add Sources/Canopy/PendingUpdate.swift
git commit -m "Offer a per-session restart for sessions on an older extension"
```

---

## Phone (Canopy-Mobile, separate PR, any time after Phase A)

Not tasked in detail here, because that repo has its own plan. It needs to:
- Send `"restart": true` on attach.
- Treat `daemon_restarting` as "expect a drop".
- Re-attach through `MirrorLiveView.reattach` on a 2 s interval within `RestartReattach.budget`, showing "Reconnecting…".
