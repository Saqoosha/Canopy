# Remote Live Sessions in the Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Other Macs' open sessions appear in the sidebar under a per-machine section, a click attaches to that Mac's `MirrorServer` and mounts the mirror in a pane, and the roster carries every open session (not only paned ones) with a `live` flag.

**Architecture:** Canopy becomes a second watcher of the relay it already publishes to (`/machines` + `/watch` WebSocket per machine), stores each machine's `RosterSnapshot`, and renders them as `SidebarRow.remoteLive` rows below the Open block. A click creates an `OpenSession` with a new `.mirror` origin; `SessionContainer` mounts a `MirrorPaneView` that drives a WKWebView through the existing `RemoteMirrorBridge` (lifted out of `#if DEBUG`) instead of a `ShimProcess`. Pairing reuses the phone's `canopy-mirror://` connection string, parsed on the Mac and stored per machine.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, `Network.framework` (`NWConnection`), `URLSessionWebSocketTask`, `Security.framework` Keychain, the DEBUG-only `_SidebarLogicProbe` for tests. Canopy-Mobile (Swift, Cloudflare Worker in TypeScript) for the last task.

**Spec:** `docs/superpowers/specs/2026-09-15-remote-sessions-sidebar-design.md` — read it first; every decision below is argued there.

## Global Constraints

- Build with `./scripts/build_debug_stable.sh` (needs Xcode 26). Probe: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy` (~3 s, prints `--- N passed, M failed`).
- Every probe fixture derives production constants from the constant, never re-types the value.
- Any `.task` on the `WindowGroup` that reaches credentials or the network needs the `CANOPY_RUN_LOGIC_PROBE` guard (`startRosterPublisher` is the precedent).
- Secrets go to the Keychain, never to `settings.json` (shared plaintext with the Release build). Never log a token.
- A closure literal written inside a `@MainActor` type and passed to a non-`@Sendable` callback aborts off-main. `DispatchSource` handlers and `NWConnection` callbacks: follow `MirrorConnection` / `RosterPublisher.makePingTimer` patterns exactly.
- `RosterSnapshot` carries no conversation content. Adding a field that quotes the transcript is out of scope.
- Commit messages in English, imperative, with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`. Do NOT push; the user decides.
- `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` (line ~442, currently 1224) is raised once, in the last task, to the count the probe reports on the finished branch.
- Comments: state facts and measurements, no metaphor. Do not insert a declaration between a `///` block and the thing it documents.

---

### Task 1: `OpenSession.Origin.mirror` and its consumers

**Files:**
- Modify: `Sources/Canopy/OpenSession.swift:22-43` (Origin), `:95-102` (projectLabel), `:196-205` (shim/webView owners)
- Modify: `Sources/Canopy/Sidebar.swift:407-418` (`finderDirectory`)
- Modify: `Sources/Canopy/PaneHeaderMenu.swift:47`
- Modify: `Sources/Canopy/SessionStore.swift:2039-2047` (capture switch)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift` (new block after the launch-restore block; search `record("restore:` to find it)

**Interfaces:**
- Produces: `OpenSession.Origin.mirror(machineId: String, host: String, port: UInt16)`; `Origin.localWorkingDirectory: URL?` (nil for `.remote` and `.mirror`); `Origin.mirrorTarget: (machineId: String, host: String, port: UInt16)?`; `OpenSession.mirrorBridge: RemoteMirrorBridge?` (declared as `AnyObject?` in this task, typed in Task 4).

- [ ] **Step 1: Write the failing probe assertions**

Append inside `runAllTests()` after the launch-restore block:

```swift
        // Mirror origin: a pane attached to another Mac's session. It has no
        // local folder, so every "open in Finder" consumer must read
        // `localWorkingDirectory` and get nil; `workingDirectory` still answers
        // (the link handler's containment guard needs a root) with $HOME.
        do {
            let mirror = OpenSession.Origin.mirror(machineId: "M1", host: "100.64.0.2", port: 8770)
            record("mirror origin: workingDirectory is the home directory",
                   mirror.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
            record("mirror origin: localWorkingDirectory is nil",
                   mirror.localWorkingDirectory == nil)
            record("mirror origin: remoteHost is nil (not an SSH session)",
                   mirror.remoteHost == nil)
            record("mirror origin: mirrorTarget carries the address",
                   mirror.mirrorTarget?.host == "100.64.0.2" && mirror.mirrorTarget?.port == 8770
                       && mirror.mirrorTarget?.machineId == "M1")
            record("local origin: localWorkingDirectory is the directory",
                   OpenSession.Origin.local(cwd).localWorkingDirectory == cwd)
            record("remote origin: localWorkingDirectory is nil",
                   OpenSession.Origin.remote(host: "studio", path: cwd).localWorkingDirectory == nil)
            let session = OpenSession(origin: mirror, resumeId: "r-m", title: "T", project: "studio · repo", status: .spawning)
            record("mirror origin: projectLabel is the roster's project verbatim",
                   session.projectLabel == "studio · repo")

            // Save-and-Quit never records a mirror pane: the session lives on
            // the other Mac and comes back only by attaching again.
            let store = SessionStore()
            store.openSessions = [session]
            _ = store.openInFocusedPane(session.id)
            let captured = store.captureRestoreSnapshot()
            record("restore: a mirror session is not captured",
                   captured.sessions.isEmpty)
        }
```

If `captureRestoreSnapshot` is spelled differently, grep `SessionRestoreSnapshot(sessions:` in `SessionStore.swift` and use the enclosing function's name; if it is `private`, make it `internal`.

- [ ] **Step 2: Build and run the probe to verify it fails**

Run: `./scripts/build_debug_stable.sh 2>&1 | tail -5`
Expected: compile error, `Origin` has no member `mirror`.

- [ ] **Step 3: Add the case and the two derived properties**

In `OpenSession.Origin`:

```swift
        /// A pane attached to a session running on ANOTHER Mac, over that
        /// Mac's `MirrorServer`. No shim, no local folder; the transcript and
        /// the CLI are on `host`.
        case mirror(machineId: String, host: String, port: UInt16)

        var workingDirectory: URL {
            switch self {
            case .local(let url): url
            case .remote(_, let path): path
            case .teleportedFrom(_, let path): path
            // `LinkClickHandler`'s containment guard needs a root; $HOME makes
            // every link outside it refused, which is right for a session
            // whose files are on the other Mac.
            case .mirror: FileManager.default.homeDirectoryForCurrentUser
            }
        }

        /// The folder Finder and the terminal can open, or nil when it is on
        /// another machine. Every "open locally" consumer reads this, not
        /// `workingDirectory`.
        var localWorkingDirectory: URL? {
            switch self {
            case .local(let url): url
            case .teleportedFrom(_, let path): path
            case .remote, .mirror: nil
            }
        }

        var remoteHost: String? {
            if case .remote(let host, _) = self { return host }
            return nil
        }

        var mirrorTarget: (machineId: String, host: String, port: UInt16)? {
            if case .mirror(let m, let h, let p) = self { return (m, h, p) }
            return nil
        }
```

In `projectLabel`, change `case .remote, .teleportedFrom:` to `case .remote, .teleportedFrom, .mirror:`.

Below `var webView: WKWebView?` add:

```swift
    /// The socket client driving `webView` for a `.mirror` origin. Strong
    /// reference, same ownership rule as `shim`: the pane view re-attaches to
    /// it on re-mount and `SessionStore.closeSession` releases it.
    var mirrorBridge: AnyObject?
```

- [ ] **Step 4: Route the Finder consumers through `localWorkingDirectory`**

`Sidebar.swift` `finderDirectory(for:)`, `.open` case: `return s.origin.localWorkingDirectory`.

`PaneHeaderMenu.swift:47`: `let workingDirectory = session.origin.localWorkingDirectory`.

- [ ] **Step 5: Exclude `.mirror` from the restore capture**

In `SessionStore.swift` capture loop, before the `switch open.origin`:

```swift
            // A mirror pane is another Mac's session; there is nothing here to
            // resume. Its pane is dropped by `sanitized` once its resumeId is
            // missing from `sessions`.
            if case .mirror = open.origin { continue }
```

Then add `case .mirror: continue` is NOT needed — the `continue` above precedes the switch, but the switch must still be exhaustive: add `case .mirror: fatalError("unreachable: filtered above")`. Prefer restructuring: compute `guard let origin = Self.restoreOrigin(for: open.origin) else { continue }` with a static returning `SessionRestoreSnapshot.Session.Origin?` that returns nil for `.mirror`. Use the static.

In `closeSession`, after `session.webView = nil` add `session.mirrorBridge = nil`.

- [ ] **Step 6: Build, run the probe, verify the new assertions pass**

Run: `./scripts/build_debug_stable.sh 2>&1 | tail -3 && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | grep -E "mirror origin|restore: a mirror|passed"`
Expected: every `mirror origin` and `restore: a mirror` line is `PASS`, and the summary shows 0 failed.

- [ ] **Step 7: Commit**

```bash
git add Sources/Canopy/OpenSession.swift Sources/Canopy/Sidebar.swift Sources/Canopy/PaneHeaderMenu.swift Sources/Canopy/SessionStore.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Add a mirror origin for panes attached to another Mac's session

- OpenSession.Origin.mirror(machineId:host:port:) with no local folder;
  workingDirectory answers \$HOME for the link handler's containment guard
- localWorkingDirectory is what Finder consumers read, nil for remote
  and mirror origins
- Save-and-Quit skips mirror sessions; their panes drop in sanitize

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Roster carries every open session, with `live`

**Files:**
- Modify: `Sources/Canopy/Roster/RosterSnapshot.swift`
- Modify: `Sources/Canopy/Roster/RosterPublisher.swift:510-569` (`snapshot()`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift` roster block (~line 1537)

**Interfaces:**
- Produces: `RosterSnapshot.Pane.live: Bool` (encoded as `"live"`); `RosterSnapshot.activity(fromWireState:) -> SessionActivity?`; `RosterSnapshot.rows(for openSessions: [OpenSession], paneIndexes: [OpenSession.ID: Int]) -> [(session: OpenSession, paneIndex: Int)]` (pure, probe-reachable: paned sessions at their strip index, unpaned ones numbered from `paneIndexes.count` upward in `openSessions` order, `.mirror` origins excluded).
- Consumes: `Origin.mirror` from Task 1.

- [ ] **Step 1: Write the failing probe assertions**

Replace the `rosterFixture` construction to pass `live: true`, then append after the JSON round-trip assertion:

```swift
        record("roster: JSON carries live",
               rosterJSON.contains("\"live\":true"))
        // The wire state is read back on the watching side; the two maps are
        // inverses so the sidebar dot and the phone dot agree.
        record("roster: wire state round-trips for every case",
               SessionActivity.allCases.allSatisfy {
                   RosterSnapshot.activity(fromWireState: RosterSnapshot.wireState(for: $0)) == $0
               })
        record("roster: an unknown wire state decodes to nil",
               RosterSnapshot.activity(fromWireState: "sleeping") == nil)

        // Every open session is published, paned or not. An unpaned one takes
        // the next index after the strip so the phone's order matches the
        // sidebar's Open block; `live` says whether an attach can succeed.
        do {
            let paned = OpenSession(origin: .local(cwd), resumeId: "rp", title: "P", project: "x", status: .live)
            let unpaned = OpenSession(origin: .local(cwd), resumeId: "ru", title: "U", project: "x", status: .dormant)
            let mirror = OpenSession(origin: .mirror(machineId: "M", host: "100.64.0.9", port: 8770),
                                     resumeId: "rm", title: "M", project: "x", status: .live)
            let rows = RosterSnapshot.rows(for: [unpaned, paned, mirror], paneIndexes: [paned.id: 0])
            record("roster rows: paned first at its strip index",
                   rows.first?.session.id == paned.id && rows.first?.paneIndex == 0)
            record("roster rows: unpaned follows, numbered after the strip",
                   rows.count == 2 && rows[1].session.id == unpaned.id && rows[1].paneIndex == 1)
            record("roster rows: a mirror session is never published",
                   !rows.contains { $0.session.id == mirror.id })
            record("roster rows: live means a shim is present",
                   RosterSnapshot.isLive(paned) == false)
        }
```

`isLive` is `session.shim != nil`; with no shim in the probe it is false, which pins the predicate's source without needing a live shim.

- [ ] **Step 2: Build, verify it fails to compile** (`live` missing, `rows`/`activity`/`isLive` undefined).

- [ ] **Step 3: Implement in `RosterSnapshot.swift`**

Add to `Pane`:

```swift
        /// Whether an attach to this session can succeed right now: true
        /// exactly when a `ShimProcess` is running for it. Pane membership is
        /// not the test — a session displaced from its pane keeps its shim,
        /// and a `.dormant` one has a pane-less row and no shim.
        let live: Bool
```

Add the statics:

```swift
    /// Inverse of `wireState(for:)`. Nil for a name this build does not know.
    static func activity(fromWireState state: String) -> SessionActivity? {
        SessionActivity.allCases.first { wireState(for: $0) == state }
    }

    static func isLive(_ session: OpenSession) -> Bool { session.shim != nil }

    /// The sessions to publish, each with its row index. Paned sessions keep
    /// their strip index; every other open session follows in `openSessions`
    /// order so the phone's list reads like the sidebar's Open block. A
    /// `.mirror` origin is skipped: it is another Mac's session, and
    /// publishing it here would show it twice on the phone and route replies
    /// to a Mac that cannot inject them.
    static func rows(for openSessions: [OpenSession], paneIndexes: [OpenSession.ID: Int])
        -> [(session: OpenSession, paneIndex: Int)] {
        var paned: [(session: OpenSession, paneIndex: Int)] = []
        var unpaned: [OpenSession] = []
        for session in openSessions {
            if case .mirror = session.origin { continue }
            if let index = paneIndexes[session.id] { paned.append((session, index)) } else { unpaned.append(session) }
        }
        paned.sort { $0.paneIndex < $1.paneIndex }
        let next = paneIndexes.count
        return paned + unpaned.enumerated().map { ($0.element, next + $0.offset) }
    }
```

- [ ] **Step 4: Use it in `RosterPublisher.snapshot()`**

Replace the `for session in store.openSessions { guard let paneIndex = ... }` loop with:

```swift
        for (session, paneIndex) in RosterSnapshot.rows(for: store.openSessions, paneIndexes: indexes) {
```

and drop the `guard let paneIndex … continue`. Add `live: RosterSnapshot.isLive(session)` to the `Pane(` call. Keep the trailing `rows.sorted { $0.paneIndex < $1.paneIndex }`. Keep the `liveIds` / `stateSince` pruning unchanged. Update the doc comment on the loop: unpaned sessions are now rows, and the comment's "paneless is routine" sentence stays true.

- [ ] **Step 5: Build, run the probe, verify the roster assertions pass and nothing else broke**

Expected: 0 failed. (The pre-existing `roster: JSON carries the keys` and round-trip lines must still pass with `live` in the fixture.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/Roster/RosterSnapshot.swift Sources/Canopy/Roster/RosterPublisher.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Publish every open session to the roster, with a live flag

- Unpaned sessions follow the paned ones, numbered after the strip, so
  the phone's order matches the sidebar's Open block
- live is shim != nil, the same test MirrorServer applies to an attach
- Mirror-origin sessions are never published
- activity(fromWireState:) is the inverse map for the watching side

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Pairing — parse the connection string, store peers

**Files:**
- Modify: `Sources/Canopy/MirrorAccess.swift`
- Modify: `Sources/Canopy/CanopySettings.swift` (property + load/save)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces: `MirrorAccess.parseConnectionString(_:) -> MirrorAccess.Connection?` where `struct Connection: Equatable { let host: String; let port: UInt16; let token: String; let machineId: String }`; `MirrorAccess.peerToken(machineId:) -> String?`; `MirrorAccess.storePeerToken(_:machineId:) -> Bool`; `MirrorAccess.forgetPeerToken(machineId:)`; `CanopySettings.mirrorPeers: [String: String]` (machineId → `host:port`), key `canopy.mirrorPeers`; `MirrorAccess.parseHostPort(_:) -> (host: String, port: UInt16)?`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
        // Pairing: the string the phone pastes is the one another Canopy
        // pastes. Builder and parser are inverses; a string with no machine id
        // is refused because the peer table is keyed on it.
        do {
            let text = MirrorAccess.connectionString(host: "100.64.0.2", port: 8770, token: "tok_A-b", machine: "M1")
            let parsed = MirrorAccess.parseConnectionString(text)
            record("pairing: connection string round-trips",
                   parsed == MirrorAccess.Connection(host: "100.64.0.2", port: 8770, token: "tok_A-b", machineId: "M1"))
            record("pairing: surrounding whitespace is tolerated",
                   MirrorAccess.parseConnectionString("  \(text)\n") == parsed)
            record("pairing: a string without machine is refused",
                   MirrorAccess.parseConnectionString("canopy-mirror://100.64.0.2:8770?token=x") == nil)
            record("pairing: a string without token is refused",
                   MirrorAccess.parseConnectionString("canopy-mirror://100.64.0.2:8770?machine=M1") == nil)
            record("pairing: another scheme is refused",
                   MirrorAccess.parseConnectionString("https://100.64.0.2:8770?token=x&machine=M1") == nil)
            record("pairing: host:port parses",
                   MirrorAccess.parseHostPort("100.64.0.2:8770")?.port == 8770)
            record("pairing: host:port without a port is refused",
                   MirrorAccess.parseHostPort("100.64.0.2") == nil)
        }
```

- [ ] **Step 2: Build, verify compile failure.**

- [ ] **Step 3: Implement in `MirrorAccess.swift`**

```swift
    // MARK: Peers (this Mac attaching to other Macs)

    struct Connection: Equatable {
        let host: String
        let port: UInt16
        let token: String
        let machineId: String
    }

    /// Inverse of `connectionString`. Nil unless scheme, host, port, token and
    /// machine are all present — the peer table is keyed on `machine`, so a
    /// string without one has nowhere to be stored.
    static func parseConnectionString(_ raw: String) -> Connection? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), components.scheme == urlScheme,
              let host = components.host, !host.isEmpty,
              let port = components.port.flatMap({ UInt16(exactly: $0) }), port != 0 else { return nil }
        let items = components.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              let machine = items.first(where: { $0.name == "machine" })?.value, !machine.isEmpty else { return nil }
        return Connection(host: host, port: port, token: token, machineId: machine)
    }

    static func parseHostPort(_ text: String) -> (host: String, port: UInt16)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon]), portText = String(text[text.index(after: colon)...])
        guard !host.isEmpty, let port = UInt16(portText), port != 0 else { return nil }
        return (host, port)
    }

    private static let peerKeychainService = "sh.saqoo.Canopy.mirror-peer"

    private static func peerQuery(machineId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: peerKeychainService,
         kSecAttrAccount as String: machineId]
    }

    static func peerToken(machineId: String) -> String? {
        var query = peerQuery(machineId: machineId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("could not read the peer password for \(machineId, privacy: .public) (OSStatus \(status))")
        }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Upsert: delete first, because `SecItemAdd` refuses a duplicate.
    static func storePeerToken(_ token: String, machineId: String) -> Bool {
        guard !token.isEmpty else { return false }
        let delete = SecItemDelete(peerQuery(machineId: machineId) as CFDictionary)
        guard delete == errSecSuccess || delete == errSecItemNotFound else {
            logger.error("could not replace the peer password for \(machineId, privacy: .public) (OSStatus \(delete))")
            return false
        }
        var query = peerQuery(machineId: machineId)
        query[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("could not store the peer password for \(machineId, privacy: .public) (OSStatus \(status))")
        }
        return status == errSecSuccess
    }

    static func forgetPeerToken(machineId: String) {
        SecItemDelete(peerQuery(machineId: machineId) as CFDictionary)
    }
```

- [ ] **Step 4: Add the setting**

In `CanopySettings` next to `mirrorPort`:

```swift
    /// Other Macs this one can attach to: machine id → `host:port`. The
    /// password for each lives in the Keychain (`MirrorAccess.peerToken`).
    var mirrorPeers: [String: String] = [:] {
        didSet { save() }
    }
```

Load: `if let peers = dict["canopy.mirrorPeers"] as? [String: String] { mirrorPeers = peers }`. Save: `dict["canopy.mirrorPeers"] = mirrorPeers`.

- [ ] **Step 5: Build, run the probe. Expected: `pairing:` lines PASS, 0 failed.**

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/MirrorAccess.swift Sources/Canopy/CanopySettings.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Parse and store another Mac's mirror connection

- parseConnectionString is the inverse of connectionString and refuses
  a string without machine or token
- Peer passwords go to the Keychain under sh.saqoo.Canopy.mirror-peer;
  addresses go to settings.json as canopy.mirrorPeers

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Lift `RemoteMirrorBridge` out of DEBUG with callbacks

**Files:**
- Create: `Sources/Canopy/MirrorClient.swift` (move `RemoteMirrorBridge` here from `MirrorAttachWindow.swift`)
- Modify: `Sources/Canopy/MirrorAttachWindow.swift` (delete the class, pass the token)
- Modify: `Sources/Canopy/OpenSession.swift` (`mirrorBridge: RemoteMirrorBridge?`)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class RemoteMirrorBridge: NSObject, WKScriptMessageHandler {
      enum Outcome: Equatable { case attached; case refused(String); case dropped }
      init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView)
      var onOutcome: ((Outcome) -> Void)?
      var extensionVersion: String?   // from attach_ok
      func close()
  }
  ```
  `.refused` is fired on `attach_error` (message verbatim from the server: `"unauthorized"`, `"no such session"`, `"expected attach"`); `.dropped` on socket `failed`, `waiting` is logged only, and on receive EOF/error. Each outcome fires at most once.

- [ ] **Step 1: Create `MirrorClient.swift`**

Move the whole `RemoteMirrorBridge` class from `MirrorAttachWindow.swift` verbatim, outside any `#if DEBUG`, then apply these edits:

```swift
    enum Outcome: Equatable { case attached, refused(String), dropped }
    var onOutcome: ((Outcome) -> Void)?
    private(set) var extensionVersion: String?
    private var outcomeDelivered = false
    private let token: String

    init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView) {
        self.token = token
        // … existing body unchanged …
    }

    private func deliverOutcome(_ outcome: Outcome) {
        guard !outcomeDelivered else { return }
        outcomeDelivered = true
        onOutcome?(outcome)
    }
```

In `stateUpdateHandler`: on `.failed` log, then `Task { @MainActor in self?.deliverOutcome(.dropped) }`. In `scheduleReceive`: on `error` and on `isComplete`, hop to main and `deliverOutcome(.dropped)` (after `closed` is false — a `close()` we asked for must not report a drop: check `guard !self.closed` inside the main hop).

In `onReady()`: replace `MirrorAccess.token(createIfMissing: true) ?? ""` with `token`.

In `handleLineData`: `attach_ok` → set `extensionVersion = dict["extensionVersion"] as? String`, `deliverOutcome(.attached)`; `attach_error` → `deliverOutcome(.refused(message))`.

- [ ] **Step 2: Update `MirrorAttachWindow`**

Construct the bridge with `token: MirrorAccess.token(createIfMissing: true) ?? ""` (it is a same-Mac test window; the comment already says so). Delete the moved class from this file. Keep the file `#if DEBUG`.

- [ ] **Step 3: Type the owner**

`OpenSession.mirrorBridge: RemoteMirrorBridge?` (replace `AnyObject?`).

- [ ] **Step 4: Build. Expected: green. Run the probe: 0 failed (no new assertions; the class is I/O).**

- [ ] **Step 5: Manual smoke (same Mac):** launch the Debug build with `CANOPY_MIRROR_LISTEN=127.0.0.1` and Settings › Mobile mirror ON, open a session, note its resumeId from the sidebar's "Copy Session ID" (or the `attach refused` log), Cmd+Shift+A → `127.0.0.1:8770/<id>`. Expected: `[mirror-attach] attach_ok` in `/usr/bin/log stream --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "MirrorAttach"'` and the window renders the conversation.

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy/MirrorClient.swift Sources/Canopy/MirrorAttachWindow.swift Sources/Canopy/OpenSession.swift
git commit -m "Move RemoteMirrorBridge out of DEBUG and report its outcome

- attached / refused(reason) / dropped, delivered once, so a pane can
  react to an attach the same way it reacts to a shim crash
- The token is a parameter; the DEBUG window keeps passing its own

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `RemoteRosterWatcher`

**Files:**
- Create: `Sources/Canopy/Roster/RemoteRosterWatcher.swift`
- Modify: `Sources/Canopy/SessionStore.swift` (two stored properties)
- Modify: `Sources/Canopy/Roster/RosterPublisher.swift:455` (`sharedSecret` → `static func sharedSecret()` internal, keep `sharedSecretForNotifier`)
- Modify: `Sources/Canopy/CanopyApp.swift` (start it; probe guard)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces: `SessionStore.remoteRosters: [String: RosterSnapshot]` (machineId → latest), `SessionStore.remoteMachineIds: [String]` (what `/machines` returned minus self, for "Loading…" rows), `RemoteRosterWatcher.decodeFrame(_ data: Data) -> RosterSnapshot?` (pure), `RemoteRosterWatcher.isStale(_:now:) -> Bool` with `static let staleThreshold: TimeInterval = 5 * 60` (matches the phone's), `RemoteRosterWatcher.peersToWatch(machines: [String], selfId: String?) -> [String]` (pure), `RemoteRosterWatcher.applyStateToMirrorSessions(...)` is Task 7's job — NOT here.
- Consumes: `RosterPublisher.sharedSecret()`, `settings.rosterEnabled`, `settings.rosterEndpoint`, `MachineIdentity.stableId()`, `RosterReconnectFloor`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
        // Remote roster watcher: the pure halves. Frame classification copies
        // the phone's rule — a snapshot carries no `type`, an event does, and
        // an event must never decode as a snapshot with no panes.
        do {
            let snapshotJSON = #"{"machineId":"M2","displayName":"studio","publishedAt":1700000000,"sessionPct":1,"weeklyPct":2,"panes":[]}"#
            let eventJSON = #"{"type":"event","machineId":"M2","panes":[]}"#
            record("watcher: a typeless frame is a snapshot",
                   RemoteRosterWatcher.decodeFrame(Data(snapshotJSON.utf8))?.machineId == "M2")
            record("watcher: a typed frame is not a snapshot",
                   RemoteRosterWatcher.decodeFrame(Data(eventJSON.utf8)) == nil)
            record("watcher: self is excluded from the peer list",
                   RemoteRosterWatcher.peersToWatch(machines: ["A", "B", "C"], selfId: "B") == ["A", "C"])
            record("watcher: a nil self id excludes nothing",
                   RemoteRosterWatcher.peersToWatch(machines: ["A"], selfId: nil) == ["A"])
            let fresh = RosterSnapshot(machineId: "M2", displayName: "s", publishedAt: 1_000, sessionPct: 0, weeklyPct: 0, panes: [])
            record("watcher: a snapshot under the threshold is fresh",
                   !RemoteRosterWatcher.isStale(fresh, now: Date(timeIntervalSince1970: 1_000 + RemoteRosterWatcher.staleThreshold - 1)))
            record("watcher: a snapshot at the threshold is stale",
                   RemoteRosterWatcher.isStale(fresh, now: Date(timeIntervalSince1970: 1_000 + RemoteRosterWatcher.staleThreshold)))
        }
```

- [ ] **Step 2: Build, verify compile failure.**

- [ ] **Step 3: Store properties**

In `SessionStore` near `cloud`:

```swift
    /// Other Macs' latest roster snapshots, keyed by machine id. Written only
    /// by `RemoteRosterWatcher`; read by the sidebar and by the mirror-state
    /// feed. A machine that has stopped publishing keeps its last snapshot,
    /// and the sidebar shows it dimmed once it is stale.
    var remoteRosters: [String: RosterSnapshot] = [:]
    /// The machine ids the relay listed, minus this Mac, in the order it gave
    /// them. A machine here with no `remoteRosters` entry yet renders as
    /// loading.
    var remoteMachineIds: [String] = []
```

- [ ] **Step 4: Write the watcher**

```swift
import Foundation
import Observation
import os.log

/// Watches the relay for the OTHER Macs' rosters, the way the phone does.
///
/// One `/watch` socket per machine, re-listed from `/machines` every
/// `listInterval`. Gated on the same two things as `RosterPublisher`:
/// `settings.rosterEnabled` and a relay secret in the Keychain. The tracked
/// pass reads `rosterEnabled` and `rosterEndpoint` unconditionally so the
/// toggle and an endpoint edit both wake it.
@MainActor
final class RemoteRosterWatcher {
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteRoster")
    private let store: SessionStore
    private let settings: CanopySettings
    private var running = false
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var pingTimers: [String: DispatchSourceTimer] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var listTimer: DispatchSourceTimer?
    private var connectedEndpoint: String?

    static let staleThreshold: TimeInterval = 5 * 60
    static let listInterval: TimeInterval = 5 * 60
    private static let pingInterval: TimeInterval = 30
    private static let reconnectFloor: TimeInterval = 5

    init(store: SessionStore, settings: CanopySettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        observe()
    }

    func stop() {
        running = false
        disconnectAll()
        listTimer?.cancel()
        listTimer = nil
        store.remoteMachineIds = []
    }

    // MARK: Pure

    /// A snapshot carries no `type`; an event or an ack does. Same rule as
    /// the phone's `RosterSocket.decode`, so an event can never be read as an
    /// empty roster.
    nonisolated static func decodeFrame(_ data: Data) -> RosterSnapshot? {
        struct TypeTag: Decodable { let type: String? }
        guard let tag = try? JSONDecoder().decode(TypeTag.self, from: data), tag.type == nil else { return nil }
        return try? JSONDecoder().decode(RosterSnapshot.self, from: data)
    }

    nonisolated static func peersToWatch(machines: [String], selfId: String?) -> [String] {
        machines.filter { $0 != selfId }
    }

    nonisolated static func isStale(_ snapshot: RosterSnapshot, now: Date) -> Bool {
        now.timeIntervalSince1970 - Double(snapshot.publishedAt) >= staleThreshold
    }

    // MARK: Tracking

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.observe()
            }
        }
    }

    private func sync() {
        let enabled = settings.rosterEnabled
        let endpoint = settings.rosterEndpoint
        guard enabled, !endpoint.isEmpty else {
            if connectedEndpoint != nil { disconnectAll(); connectedEndpoint = nil }
            return
        }
        if connectedEndpoint != endpoint {
            disconnectAll()
            connectedEndpoint = endpoint
            startListing()
        }
    }

    // MARK: /machines

    private func startListing() {
        listTimer?.cancel()
        let timer = Self.makeListTimer(interval: Self.listInterval) { [weak self] in
            Task { @MainActor in self?.refreshMachineList() }
        }
        listTimer = timer
        timer.resume()
        refreshMachineList()
    }

    private nonisolated static func makeListTimer(interval: TimeInterval, tick: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        return timer
    }

    private func refreshMachineList() {
        guard let base = relayURL(path: "/machines"), let secret = RosterPublisher.sharedSecret() else { return }
        var request = URLRequest(url: base)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self?.logger.error("remote roster: /machines returned \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                    return
                }
                let ids = try JSONDecoder().decode([String].self, from: data)
                self?.applyMachineList(ids)
            } catch {
                self?.logger.error("remote roster: /machines failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyMachineList(_ ids: [String]) {
        let peers = Self.peersToWatch(machines: ids, selfId: MachineIdentity.stableId())
        store.remoteMachineIds = peers
        for gone in sockets.keys where !peers.contains(gone) { disconnect(machine: gone) }
        for id in peers where sockets[id] == nil { connect(machine: id) }
    }

    // MARK: /watch

    private func relayURL(path: String, machine: String? = nil, scheme: String? = nil) -> URL? {
        guard var components = URLComponents(string: settings.rosterEndpoint), components.scheme == "https" else {
            logger.error("remote roster: endpoint must be https")
            return nil
        }
        components.path = path
        if let machine { components.queryItems = [URLQueryItem(name: "machine", value: machine)] }
        if let scheme { components.scheme = scheme }
        return components.url
    }

    private func connect(machine: String) {
        guard let url = relayURL(path: "/watch", machine: machine, scheme: "wss"),
              let secret = RosterPublisher.sharedSecret() else { return }
        lastAttempt[machine] = Date()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        sockets[machine] = task
        task.resume()
        startPinging(machine: machine, task: task)
        receive(machine: machine, on: task)
        logger.notice("remote roster: watching \(machine, privacy: .public)")
    }

    private func receive(machine: String, on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.sockets[machine] === task else { return }
                switch result {
                case .success(let message):
                    let data: Data? = switch message {
                    case .data(let d): d
                    case .string(let s): Data(s.utf8)
                    @unknown default: nil
                    }
                    if let data, let snapshot = Self.decodeFrame(data) {
                        self.store.remoteRosters[machine] = snapshot
                    }
                    self.receive(machine: machine, on: task)
                case .failure(let error):
                    self.logger.error("remote roster: \(machine, privacy: .public) socket lost: \(error.localizedDescription, privacy: .public)")
                    self.disconnect(machine: machine)
                    self.scheduleReconnect(machine: machine)
                }
            }
        }
    }

    private func scheduleReconnect(machine: String) {
        guard running, store.remoteMachineIds.contains(machine) else { return }
        switch RosterReconnectFloor.decide(last: lastAttempt[machine], now: Date(), floor: Self.reconnectFloor) {
        case .now:
            connect(machine: machine)
        case .after(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.sockets[machine] == nil else { return }
                    self.connect(machine: machine)
                }
            }
        }
    }

    private func startPinging(machine: String, task: URLSessionWebSocketTask) {
        pingTimers[machine]?.cancel()
        let timer = Self.makePingTimer(for: task, interval: Self.pingInterval) { [weak self] failed, error in
            Task { @MainActor in
                guard let self, self.sockets[machine] === failed else { return }
                self.logger.error("remote roster: ping to \(machine, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.disconnect(machine: machine)
                self.scheduleReconnect(machine: machine)
            }
        }
        pingTimers[machine] = timer
        timer.resume()
    }

    /// `nonisolated` for the reason `RosterPublisher.makePingTimer` records:
    /// the handler is not `@Sendable`, so a literal written inside this actor
    /// would abort on the timer's queue.
    private nonisolated static func makePingTimer(
        for task: URLSessionWebSocketTask, interval: TimeInterval,
        onFailure: @escaping @Sendable (URLSessionWebSocketTask, Error) -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak task] in
            guard let task else { return }
            task.sendPing { error in
                guard let error else { return }
                onFailure(task, error)
            }
        }
        return timer
    }

    private func disconnect(machine: String) {
        pingTimers[machine]?.cancel()
        pingTimers[machine] = nil
        sockets[machine]?.cancel(with: .goingAway, reason: nil)
        sockets[machine] = nil
    }

    private func disconnectAll() {
        for machine in Array(sockets.keys) { disconnect(machine: machine) }
    }
}
```

Make `RosterPublisher.sharedSecret()` `static func` (drop `private`); keep `sharedSecretForNotifier` as is.

- [ ] **Step 5: Start it from the app**

In `CanopyApp.swift` next to `.task { appDelegate.startRosterPublisher(store: sidebarStore) }` add `.task { appDelegate.startRemoteRosterWatcher(store: sidebarStore) }`. In `AppDelegate`:

```swift
    private var remoteRosterWatcher: RemoteRosterWatcher?

    /// Same probe guard as `startRosterPublisher`, for the same reason: this
    /// `.task` runs before `applicationDidFinishLaunching` exits the probe,
    /// and it reads the relay secret and opens sockets.
    @MainActor
    func startRemoteRosterWatcher(store: SessionStore) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { return }
        #endif
        guard remoteRosterWatcher == nil else { return }
        let watcher = RemoteRosterWatcher(store: store, settings: CanopySettings.shared)
        remoteRosterWatcher = watcher
        watcher.start()
    }
```

In `applicationWillTerminate` next to `rosterPublisher?.stop()` add `remoteRosterWatcher?.stop()`.

- [ ] **Step 6: Build, run the probe. Expected: `watcher:` lines PASS, 0 failed, and zero `RemoteRoster` log lines during the probe run:**

`/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "RemoteRoster"' --last 2m --style compact` → empty.

- [ ] **Step 7: Live check:** launch the Debug build with roster enabled; expected `remote roster: watching <studio's id>` in the log within a few seconds, and `store.remoteRosters` non-empty (add a temporary `logger.notice` on receipt if needed, remove before commit).

- [ ] **Step 8: Commit**

```bash
git add Sources/Canopy/Roster/RemoteRosterWatcher.swift Sources/Canopy/Roster/RosterPublisher.swift Sources/Canopy/SessionStore.swift Sources/Canopy/CanopyApp.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Watch the relay for other Macs' rosters

- One /watch socket per machine listed by /machines, re-listed every
  five minutes, pinged every 30 s, reconnected behind the shared floor
- Frames are classified by the presence of type, as on the phone
- Guarded against the logic probe like the publisher

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Sidebar rows for remote live sessions

**Files:**
- Modify: `Sources/Canopy/SidebarRow.swift`
- Modify: `Sources/Canopy/Sidebar.swift` (sections ~line 54-90; `rowMenu` ~338; `handleClick`; `SidebarRowView.iconView` / `openIconSize` / `openIconWeight` / `iconName` / `iconTint` switches)
- Modify: `Sources/Canopy/SessionStore.swift` (`remoteLiveSections`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:
  ```swift
  struct RemoteLiveSession: Hashable {
      let machineId: String
      let machineName: String
      let row: RosterSnapshot.Pane
      let stale: Bool
      var sessionId: String { row.resumeId ?? row.sessionId }
  }
  case remoteLive(RemoteLiveSession)   // on SidebarRow; id "remote:<machineId>:<sessionId>"
  struct RemoteMachineSection: Identifiable { let machineId: String; let title: String; let rows: [SidebarRow]; let loading: Bool; var id: String { machineId } }
  static func remoteLiveSections(rosters: [String: RosterSnapshot], machineIds: [String], attached: Set<String>, now: Date) -> [RemoteMachineSection]   // on SessionStore, pure
  var remoteLiveSections: [RemoteMachineSection]   // on SessionStore, instance
  ```
  `attached` holds `"<machineId>:<sessionId>"` keys of open `.mirror` sessions; rows with a matching key are dropped. `SidebarRow.canOpen(.remoteLive(r))` is `r.row.live && !r.stale`. `openRemoteLive(_:target:)` on `SessionStore` is Task 7 — this task's click handler calls it, so add a stub that only logs (`logger.notice("openRemoteLive: not implemented")`) and replace it in Task 7.
- Consumes: `RosterSnapshot.Pane.live`, `activity(fromWireState:)`, `RemoteRosterWatcher.isStale`, `store.remoteRosters`, `store.remoteMachineIds`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
        // Remote live rows: built from other Macs' rosters, per machine, with
        // already-attached sessions removed (their pane has an Open row).
        do {
            func pane(_ id: String, live: Bool, state: String = "idle") -> RosterSnapshot.Pane {
                RosterSnapshot.Pane(sessionId: id, resumeId: id, paneIndex: 0, title: "T \(id)", project: "P",
                                    state: state, stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: live)
            }
            let now = Date(timeIntervalSince1970: 2_000)
            let fresh = RosterSnapshot(machineId: "M2", displayName: "studio", publishedAt: 2_000, sessionPct: 0, weeklyPct: 0,
                                       panes: [pane("a", live: true, state: "working"), pane("b", live: false)])
            let old = RosterSnapshot(machineId: "M3", displayName: "mini", publishedAt: 0, sessionPct: 0, weeklyPct: 0,
                                     panes: [pane("c", live: true)])
            let sections = SessionStore.remoteLiveSections(
                rosters: ["M2": fresh, "M3": old], machineIds: ["M3", "M2", "M4"], attached: ["M2:b"], now: now)
            record("remote rows: one section per listed machine, in relay order",
                   sections.map(\.machineId) == ["M3", "M2", "M4"])
            record("remote rows: a machine with no snapshot yet is loading",
                   sections[2].loading && sections[2].rows.isEmpty)
            record("remote rows: the section title is the display name",
                   sections[1].title == "studio")
            record("remote rows: an attached session's row is dropped",
                   sections[1].rows.map(\.id) == ["remote:M2:a"])
            record("remote rows: a stale machine's rows are marked stale",
                   { if case .remoteLive(let r) = sections[0].rows[0] { return r.stale } else { return false } }())
            record("remote rows: a live fresh row can open",
                   SidebarRow.canOpen(sections[1].rows[0]))
            record("remote rows: a stale row cannot open",
                   !SidebarRow.canOpen(sections[0].rows[0]))
            let dead = RemoteLiveSession(machineId: "M2", machineName: "studio", row: pane("b", live: false), stale: false)
            record("remote rows: a non-live row cannot open",
                   !SidebarRow.canOpen(.remoteLive(dead)))
            record("remote rows: the row is not in the Open block",
                   !SidebarRow.remoteLive(dead).isOpen)
            record("remote rows: activity comes from the wire state",
                   { if case .remoteLive(let r) = sections[1].rows[0] { return r.activity == .working } else { return false } }())
        }
```

- [ ] **Step 2: Build, verify compile failure.**

- [ ] **Step 3: `SidebarRow.swift`**

Add the struct above the enum:

```swift
/// One of another Mac's open sessions, as the relay last reported it.
struct RemoteLiveSession: Hashable {
    let machineId: String
    let machineName: String
    let row: RosterSnapshot.Pane
    /// The publishing Mac has not been heard from for `RemoteRosterWatcher.staleThreshold`.
    let stale: Bool

    /// The id an attach names: the CLI's own, which `MirrorServer` matches on
    /// `OpenSession.resumeId`. Falls back to the process id for a pane
    /// published before its backfill.
    var sessionId: String { row.resumeId ?? row.sessionId }

    /// Idle when stale: a dot breathing "working" on a Mac that stopped
    /// publishing an hour ago is a lie.
    var activity: SessionActivity {
        stale ? .idle : (RosterSnapshot.activity(fromWireState: row.state) ?? .idle)
    }
}
```

`RosterSnapshot.Pane` must be `Hashable` — add it to its conformance list.

Add `case remoteLive(RemoteLiveSession)` and extend every switch:
- `id`: `case .remoteLive(let r): "remote:\(r.machineId):\(r.sessionId)"`
- `title`: `r.row.title`
- `project`: `r.row.project`
- `lastModified`: `Date(timeIntervalSince1970: TimeInterval(r.row.stateSince))`
- `isOpen`: false
- `canOpen`: `case .remoteLive(let r): r.row.live && !r.stale`
- `origin`: `.local` is wrong and `.cloud` is wrong; add `case remote` to `Origin` — but `SidebarFilter` enumerates `Origin.allCases` for its picker. Check `SidebarFilter.swift`: if it renders a picker over `allCases`, adding a case adds a filter option that never matches anything in `visibleRows` (remote rows bypass the filter). Acceptable; label it "Other Macs" wherever `Origin` is rendered. Grep `case .cloud` in `SidebarFilter.swift` and `Sidebar.swift` and add the sibling.
- `sorted`, `deduped`: no change; remote rows never enter them.

- [ ] **Step 4: `SessionStore` sections**

```swift
    struct RemoteMachineSection: Identifiable {
        let machineId: String
        let title: String
        let rows: [SidebarRow]
        let loading: Bool
        var id: String { machineId }
    }

    /// Other Macs' rows, one section per listed machine, in the relay's order.
    /// Pure so the probe pins the drop rule: a session this Mac has already
    /// attached to has a pane and an Open row, so its remote row would be a
    /// duplicate — the teleported-cloud-row rule, one hop over.
    static func remoteLiveSections(rosters: [String: RosterSnapshot], machineIds: [String],
                                   attached: Set<String>, now: Date) -> [RemoteMachineSection] {
        machineIds.map { id in
            guard let snapshot = rosters[id] else {
                return RemoteMachineSection(machineId: id, title: id, rows: [], loading: true)
            }
            let stale = RemoteRosterWatcher.isStale(snapshot, now: now)
            let rows = snapshot.panes.compactMap { pane -> SidebarRow? in
                let live = RemoteLiveSession(machineId: id, machineName: snapshot.displayName, row: pane, stale: stale)
                return attached.contains("\(id):\(live.sessionId)") ? nil : .remoteLive(live)
            }
            return RemoteMachineSection(machineId: id, title: snapshot.displayName, rows: rows, loading: false)
        }
    }

    var remoteLiveSections: [RemoteMachineSection] {
        let attached = Set(openSessions.compactMap { s -> String? in
            guard let t = s.origin.mirrorTarget else { return nil }
            return "\(t.machineId):\(s.resumeId)"
        })
        return Self.remoteLiveSections(rosters: remoteRosters, machineIds: remoteMachineIds, attached: attached, now: Date())
    }

    /// Replaced in the next task.
    func openRemoteLive(_ remote: RemoteLiveSession, target: PaneTarget) {
        logger.notice("openRemoteLive: not implemented yet")
    }
```

- [ ] **Step 5: `Sidebar.swift`**

Between the Open section and the closed sections in the `List`:

```swift
                ForEach(store.remoteLiveSections) { section in
                    Section(section.title) {
                        if section.loading {
                            Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if section.rows.isEmpty {
                            Text("No sessions").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(section.rows, id: \.id) { row in
                            rowView(row)
                        }
                    }
                }
```

`rowView` for remote rows: they are closed-style rows (tap gesture, `.selectionDisabled`) — follow whatever branch `.closedCloud` takes in `rowView`; add `.remoteLive` beside `.closedCloud` in every switch there. Add `.help(...)` on the row when `!canOpen(row)`: `"Not running on \(r.machineName)"` for `!r.row.live`, `"\(r.machineName) has not published for a while"` for stale.

`rowMenu`: `.remoteLive` renders no Rename; add `Button("Copy Session ID") { store.copyToPasteboard(r.sessionId) }`; the Hide button stays disabled for it (add to the `.disabled(...)` predicate: `row.isOpen || isRemoteLive(row)`). `finderDirectory`, `sessionLogPath`: `.remoteLive` → nil.

`handleClick`: 

```swift
        case .remoteLive(let remote):
            guard canOpen(row) else { return }
            if addNewPane && store.panes.count >= SessionStore.paneAbsoluteCap {
                store.showCapReachedHintOnFocusedPane()
                store.openRemoteLive(remote, target: .focused)
            } else {
                store.openRemoteLive(remote, target: addNewPane ? .newPane : .focused)
            }
```

`handleClose`: `.remoteLive: break`.

`SidebarRowView.iconView`: add before the generic `Image` branch:

```swift
        } else if case .remoteLive(let remote) = row {
            ActivityDot(activity: remote.activity)
                .opacity(remote.stale ? 0.5 : 1)
```

Add `.remoteLive` to `openIconSize` (6), `openIconWeight` (.regular), `iconName` ("circle.fill", unreachable like `.open`), `iconTint` (.secondary). Dim the whole row when stale: in `body`, `.opacity(isStaleRemote ? 0.5 : 1)` where `isStaleRemote` pattern-matches the row.

- [ ] **Step 6: Build, run the probe. Expected: `remote rows:` PASS, 0 failed.**

- [ ] **Step 7: Live check:** Debug build with roster on and studio publishing. Expected: a "studio" section under Open with its sessions and coloured dots; a session studio has not paned (dormant) shows with a greyed row and the "Not running" tooltip. Take a window-scoped screenshot (`screencapture -l <windowid>`), never full screen.

- [ ] **Step 8: Commit**

```bash
git add Sources/Canopy/SidebarRow.swift Sources/Canopy/Sidebar.swift Sources/Canopy/SessionStore.swift Sources/Canopy/Roster/RosterSnapshot.swift Sources/Canopy/SidebarFilter.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "List other Macs' open sessions in the sidebar

- One section per machine the relay lists, between Open and Recents,
  rows built from the machine's roster with the same ActivityDot
- A session already attached here is dropped from its remote section
- Rows that cannot be attached (no shim, or a stale Mac) are disabled
  with a tooltip saying which

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Attach into a pane

**Files:**
- Create: `Sources/Canopy/MirrorPaneView.swift`
- Modify: `Sources/Canopy/SessionContainer.swift`
- Modify: `Sources/Canopy/SessionStore.swift` (`openRemoteLive` real body; `noteRemoteState`)
- Modify: `Sources/Canopy/Roster/RemoteRosterWatcher.swift` (call `store.noteRemoteState` on each snapshot)
- Modify: `Sources/Canopy/StatusBarData.swift` (`mirrorMachine: String?`) and `StatusBarView.swift` (render it where `remoteHost` renders)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces: `SessionStore.openRemoteLive(_ remote: RemoteLiveSession, target: PaneTarget)`; `SessionStore.remoteAttachRefusal(machineName:)` → `String?` (nil when paired); `SessionStore.noteRemoteState(machineId: String, snapshot: RosterSnapshot)` (writes `isThinking`/`isAsking`/`isWaiting`/`statusBar` fields on matching `.mirror` sessions); `SessionStore.mirrorFailureMessage(reason: String, machineName: String) -> String` (pure); `MirrorPaneView(session: OpenSession, onFailure: (String) -> Void)`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
        // Attaching to a remote session. Pure decisions only; the socket is
        // measured on device.
        do {
            record("attach: unauthorized names the Settings fix",
                   SessionStore.mirrorFailureMessage(reason: "unauthorized", machineName: "studio")
                       == "studio rejected the password. Paste its connection again in Settings › Mobile.")
            record("attach: no such session says it stopped",
                   SessionStore.mirrorFailureMessage(reason: "no such session", machineName: "studio")
                       == "That session is no longer running on studio.")
            record("attach: an unknown reason is passed through with the machine",
                   SessionStore.mirrorFailureMessage(reason: "expected attach", machineName: "studio")
                       == "studio refused the attach: expected attach")

            let store = SessionStore()
            let remote = RemoteLiveSession(
                machineId: "M2", machineName: "studio",
                row: RosterSnapshot.Pane(sessionId: "s", resumeId: "r-live", paneIndex: 0, title: "T", project: "P",
                                         state: "idle", stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: true),
                stale: false)
            let existing = OpenSession(origin: .mirror(machineId: "M2", host: "100.64.0.2", port: 8770),
                                       resumeId: "r-live", title: "T", project: "P", status: .live)
            let other = OpenSession(origin: .local(cwd), resumeId: "x", title: "X", project: "P", status: .live)
            store.openSessions = [existing, other]
            _ = store.openInNewPane(existing.id)
            _ = store.openInNewPane(other.id)
            store.setFocusedPaneIndex(1)
            store.openRemoteLive(remote, target: .focused)
            record("attach: a second attach to the same session focuses its pane",
                   store.openSessions.count == 2 && store.focusedPaneIndex == 0)

            // State arrives from the roster, since a mirror has no shim.
            let snapshot = RosterSnapshot(machineId: "M2", displayName: "studio", publishedAt: 0, sessionPct: 0, weeklyPct: 0,
                                          panes: [RosterSnapshot.Pane(sessionId: "s", resumeId: "r-live", paneIndex: 0, title: "T", project: "P",
                                                                      state: "asking", stateSince: 0, contextPct: 42, model: "opus", messageCount: 7, live: true)])
            store.noteRemoteState(machineId: "M2", snapshot: snapshot)
            record("attach: asking on the wire raises isAsking on the mirror session",
                   existing.isAsking && !existing.isThinking && !existing.isWaiting)
            record("attach: the status bar takes the roster's model and message count",
                   existing.statusBar.model == "opus" && existing.statusBar.messageCount == 7)
            record("attach: a local session is untouched by a remote snapshot",
                   !other.isAsking)
        }
```

`openRemoteLive` with no pairing must not create a session in the probe — the fixture above only exercises the already-attached branch, which runs before the pairing check. `StatusBarData.model` and `messageCount` are stored properties; `contextPct` is COMPUTED from `contextUsed` / `compactionWindow` and cannot be fed a percentage, so a mirror pane's context meter stays empty (recorded in the spec's 見送り list in Task 10).

- [ ] **Step 2: Build, verify compile failure.**

- [ ] **Step 3: `SessionStore` additions**

```swift
    /// Why an attach cannot even start, or nil when this Mac holds the peer's
    /// address and password.
    func remoteAttachRefusal(machineId: String, machineName: String) -> String? {
        guard let address = CanopySettings.shared.mirrorPeers[machineId],
              MirrorAccess.parseHostPort(address) != nil,
              MirrorAccess.peerToken(machineId: machineId) != nil else {
            return "Paste \(machineName)'s connection in Settings › Mobile first."
        }
        return nil
    }

    static func mirrorFailureMessage(reason: String, machineName: String) -> String {
        switch reason {
        case "unauthorized": "\(machineName) rejected the password. Paste its connection again in Settings › Mobile."
        case "no such session": "That session is no longer running on \(machineName)."
        default: "\(machineName) refused the attach: \(reason)"
        }
    }

    /// The most recent attach refusal that never reached a pane (no pairing),
    /// for the sidebar to show. Cleared when the user dismisses it.
    var remoteAttachError: String?

    func openRemoteLive(_ remote: RemoteLiveSession, target: PaneTarget) {
        if let existing = openSessions.first(where: {
            $0.origin.mirrorTarget?.machineId == remote.machineId && $0.resumeId == remote.sessionId
        }) {
            switch target {
            case .focused: select(.session(existing.id))
            case .newPane:
                if !openInNewPane(existing.id) {
                    if panes.count >= Self.paneAbsoluteCap { showCapReachedHintOnFocusedPane() }
                    openInFocusedPane(existing.id)
                }
            }
            return
        }
        if let refusal = remoteAttachRefusal(machineId: remote.machineId, machineName: remote.machineName) {
            remoteAttachError = refusal
            logger.notice("openRemoteLive: refused before attach for \(remote.machineId, privacy: .public)")
            return
        }
        guard let address = CanopySettings.shared.mirrorPeers[remote.machineId],
              let hostPort = MirrorAccess.parseHostPort(address) else { return }
        let session = OpenSession(
            origin: .mirror(machineId: remote.machineId, host: hostPort.host, port: hostPort.port),
            resumeId: remote.sessionId,
            title: remote.row.title,
            project: remote.row.project,
            status: .spawning,
            resumeIdIsExistingTranscript: true
        )
        session.statusBar.mirrorMachine = remote.machineName
        openSessions.append(session)
        switch target {
        case .focused: select(.session(session.id))
        case .newPane:
            if !openInNewPane(session.id) {
                if panes.count >= Self.paneAbsoluteCap { showCapReachedHintOnFocusedPane() }
                openInFocusedPane(session.id)
            }
        }
        logger.notice("openRemoteLive: attaching \(remote.sessionId, privacy: .public) on \(remote.machineId, privacy: .public)")
    }

    /// Feeds a mirror session's activity from its home Mac's roster: a mirror
    /// has no shim, so nothing else writes these.
    func noteRemoteState(machineId: String, snapshot: RosterSnapshot) {
        for session in openSessions where session.origin.mirrorTarget?.machineId == machineId {
            guard let pane = snapshot.panes.first(where: { ($0.resumeId ?? $0.sessionId) == session.resumeId }) else { continue }
            let activity = RosterSnapshot.activity(fromWireState: pane.state)
            session.isThinking = activity == .working
            session.isAsking = activity == .asking
            session.isWaiting = activity == .background
            session.statusBar.model = pane.model
            session.statusBar.messageCount = pane.messageCount
        }
    }
```

`select(_:)` exists (used by `openLocal`). Note `.unread` is deliberately not mirrored: unread is this Mac's own bookkeeping.

In `RemoteRosterWatcher.receive`, after `self.store.remoteRosters[machine] = snapshot` add `self.store.noteRemoteState(machineId: machine, snapshot: snapshot)`.

Sidebar: render `store.remoteAttachError` the way `teleportError` is rendered (same overlay block, second `if let`), with a dismiss that sets it nil.

- [ ] **Step 4: `StatusBarData.mirrorMachine`**

Add `var mirrorMachine: String?` beside `remoteHost`, clear it in `resetAll()`. In `StatusBarView`, wherever `data.remoteHost` is drawn (lines ~53 and ~136), draw `data.mirrorMachine` the same way with `antenna.radiowaves.left.and.right` as the symbol; `hasRemote` becomes `data.remoteHost != nil || data.mirrorMachine != nil`.

- [ ] **Step 5: `MirrorPaneView.swift`**

```swift
import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorPane")

/// A pane showing another Mac's session: the same WKWebView `WebViewContainer`
/// builds, driven over TCP by `RemoteMirrorBridge` instead of by a shim.
/// Reuses `SessionWebViewHost` so a pane swap is the same in-place subview
/// move, and the two-hosts-one-webview re-adoption rule holds here too.
struct MirrorPaneView: NSViewRepresentable {
    let session: OpenSession
    /// Called once with a user-facing message when the attach is refused or the
    /// socket drops before `attach_ok`; the caller closes the pane.
    let onFailure: (String) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var consoleHandler: ConsoleLogHandler?
        var linkHandler: LinkClickHandler?
        var inputWidthHandler: InputWidthMessageHandler?
        var lastBoundSessionId: OpenSession.ID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SessionWebViewHost {
        let host = SessionWebViewHost()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        SessionWebViewHost.install(webView(coordinator: context.coordinator), in: host)
        context.coordinator.lastBoundSessionId = session.id
        return host
    }

    func updateNSView(_ host: SessionWebViewHost, context: Context) {
        guard session.id != context.coordinator.lastBoundSessionId else {
            host.adoptExpectedWebViewIfNeeded()
            return
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        SessionWebViewHost.install(webView(coordinator: context.coordinator), in: host)
        context.coordinator.lastBoundSessionId = session.id
    }

    static func dismantleNSView(_ host: SessionWebViewHost, coordinator: Coordinator) {
        for sub in host.subviews {
            if let wk = sub as? WKWebView {
                wk.navigationDelegate = nil
                let ucc = wk.configuration.userContentController
                for name in ["vscodeHost", "consoleLog", "canopyLink", InputWidthProbe.messageHandlerName] {
                    ucc.removeScriptMessageHandler(forName: name)
                }
            }
            sub.removeFromSuperview()
        }
    }

    /// The cached webview when the session already has one; otherwise a fresh
    /// webview and bridge, attached in the order the DEBUG window measured:
    /// socket ready → `attach` → page load.
    private func webView(coordinator: Coordinator) -> WKWebView {
        if let cached = session.webView, session.mirrorBridge != nil {
            cached.navigationDelegate = coordinator
            return cached
        }
        guard let target = session.origin.mirrorTarget,
              let token = MirrorAccess.peerToken(machineId: target.machineId) else {
            logger.error("[mirror-pane] no pairing for \(session.origin.mirrorTarget?.machineId ?? "nil", privacy: .public)")
            DispatchQueue.main.async { onFailure("No password stored for this Mac.") }
            return WKWebView()
        }
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        WebViewContainer.addSessionUserScripts(to: ucc)
        let consoleHandler = ConsoleLogHandler()
        ucc.add(consoleHandler, name: "consoleLog")
        let linkHandler = LinkClickHandler(workingDirectory: session.origin.workingDirectory)
        ucc.add(linkHandler, name: "canopyLink")
        let inputWidthHandler = InputWidthMessageHandler(statusBarData: session.statusBar)
        ucc.add(inputWidthHandler, name: InputWidthProbe.messageHandlerName)
        let webView = SessionWKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = coordinator

        let bridge = RemoteMirrorBridge(host: target.host, port: target.port, sessionId: session.resumeId, token: token, webView: webView)
        ucc.add(bridge, name: "vscodeHost")
        let machineName = session.statusBar.mirrorMachine ?? target.machineId
        bridge.onOutcome = { [weak session] outcome in
            guard let session else { return }
            switch outcome {
            case .attached:
                session.status = .live
                if let remote = bridge.extensionVersion, let local = CCExtension.extensionVersion(), remote != local {
                    logger.notice("[mirror-pane] extension \(local, privacy: .public) here, \(remote, privacy: .public) on \(machineName, privacy: .public)")
                }
            case .refused(let reason):
                onFailure(SessionStore.mirrorFailureMessage(reason: reason, machineName: machineName))
            case .dropped:
                if case .spawning = session.status {
                    onFailure("Could not reach \(machineName). Is its live mirror on?")
                } else {
                    session.connection.status = .reconnectFailed
                }
            }
        }
        session.connection.onRetry = { [weak session] in
            guard let session else { return }
            session.connection.status = .connected
            session.mirrorBridge?.close()
            session.mirrorBridge = nil
            session.webView = nil
            // Re-mount builds a fresh bridge and webview; the server replays the transcript.
            session.restartGeneration += 1
        }
        session.webView = webView
        session.mirrorBridge = bridge
        coordinator.consoleHandler = consoleHandler
        coordinator.linkHandler = linkHandler
        coordinator.inputWidthHandler = inputWidthHandler
        return webView
    }
}
```

`SessionWKWebView` is the subclass `WebViewContainer` uses; confirm its initializer is accessible (it is in the same module). `ConnectionState.statusMessage` for `.reconnectFailed` says "Could not reconnect" — acceptable for v1.

- [ ] **Step 6: `SessionContainer` branch**

Replace the `WebViewContainer(` call with:

```swift
                if session.origin.mirrorTarget != nil {
                    MirrorPaneView(session: session) { message in
                        session.lastFatalError = message
                        onCrash?(-2)
                    }
                    .overlay { ConnectionOverlayView(connectionState: session.connection, onBackToLauncher: { session.connection.status = .connected }) }
                    .animation(.easeInOut(duration: 0.3), value: session.connection.isOverlayVisible)
                } else {
                    WebViewContainer( /* unchanged */ )
                        .overlay { /* unchanged */ }
                        .animation(/* unchanged */)
                }
```

`Detail.swift`'s crash closure already passes `session.lastFatalError` to `noteSessionFailure`, so the message reaches the launcher banner. Change the `SpawningOverlay` headline: `session.origin.mirrorTarget != nil ? "Attaching to \(session.statusBar.mirrorMachine ?? "remote Mac")…" : "Starting \(session.title)…"`. The `.task` that flips `.spawning → .live` after 1.2 s must NOT run for a mirror (the bridge flips it on `attach_ok`): wrap it in `if session.origin.mirrorTarget == nil`.

- [ ] **Step 7: Build, run the probe. Expected: `attach:` lines PASS, 0 failed.**

- [ ] **Step 8: On-device (MBP ↔ studio)** — the spike's rig:
  1. `rsync` the Debug app to studio; on studio: `open -n --env CANOPY_MIRROR_LISTEN=<studio tailscale ip> <app>` with Settings › Mobile mirror ON; Copy Connection for iPhone there and paste the string into a note.
  2. On this Mac: Settings › Mobile › Other Macs › Paste (Task 8 — until then, write `canopy.mirrorPeers` into settings.json by hand and store the token with a one-off `security add-generic-password -s sh.saqoo.Canopy.mirror-peer -a <machineId> -w`). Never echo the token.
  3. Click a live studio row. Expected: `Attaching to studio…` overlay, then the conversation; `[mirror-attach] attach_ok` in the log; typing a prompt runs on studio and renders here; the sidebar's studio section no longer lists that session; its dot follows studio's state.
  4. Turn studio's mirror off. Expected: overlay "Could not reconnect" with Retry; turn it on, Retry → conversation back.
  5. Quit with the pane open: no Save-and-Quit prompt if nothing else runs; relaunch: no mirror pane.

- [ ] **Step 9: Commit**

```bash
git add Sources/Canopy/MirrorPaneView.swift Sources/Canopy/SessionContainer.swift Sources/Canopy/SessionStore.swift Sources/Canopy/Roster/RemoteRosterWatcher.swift Sources/Canopy/StatusBarData.swift Sources/Canopy/StatusBarView.swift Sources/Canopy/Sidebar.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Attach to another Mac's session from its sidebar row

- A mirror-origin OpenSession mounts MirrorPaneView: the pane's webview
  driven by RemoteMirrorBridge over TCP instead of by a shim
- Attach refusals close the pane through the launcher banner with the
  reason; a dropped socket shows the connection overlay with Retry
- The session's activity and status-bar figures come from its home
  Mac's roster, since a mirror has no shim to report them
- A second click on an attached session focuses its pane

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Settings › Mobile › Other Macs

**Files:**
- Modify: `Sources/Canopy/SettingsView.swift` `MobileSettingsTab` (after the Live mirror section)
- Modify: `Sources/Canopy/Sidebar.swift` (the refusal overlay's "Open Settings" button)

**Interfaces:**
- Consumes: `MirrorAccess.parseConnectionString`, `storePeerToken`, `forgetPeerToken`, `CanopySettings.mirrorPeers`, `store.remoteRosters` (for display names).

- [ ] **Step 1: Add the section**

```swift
            Section {
                if settings.mirrorPeers.isEmpty {
                    Text("No other Macs paired.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.mirrorPeers.keys.sorted(), id: \.self) { machine in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peerName(machine))
                            Text(settings.mirrorPeers[machine] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { forgetPeer(machine) }
                    }
                }
                HStack {
                    Button("Paste Connection from Mac") { pastePeerConnection() }
                    Spacer()
                    if let peerNotice {
                        Text(peerNotice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Other Macs")
            } footer: {
                SettingsFooter(text: "On the other Mac, turn on its live mirror and use Copy Connection for iPhone; then paste here. Its sessions appear in this Mac's sidebar once both Macs publish to the same relay.")
            }
```

With:

```swift
    @State private var peerNotice: String?

    private func peerName(_ machine: String) -> String {
        SessionStore.shared?.remoteRosters[machine]?.displayName ?? machine
    }

    private func pastePeerConnection() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let connection = MirrorAccess.parseConnectionString(text) else {
            peerNotice = "That is not a Canopy connection (expected canopy-mirror://…)."
            return
        }
        guard MirrorAccess.storePeerToken(connection.token, machineId: connection.machineId) else {
            peerNotice = "Could not store the password in the Keychain."
            return
        }
        settings.mirrorPeers[connection.machineId] = "\(connection.host):\(connection.port)"
        peerNotice = "Paired with \(peerName(connection.machineId))."
    }

    private func forgetPeer(_ machine: String) {
        MirrorAccess.forgetPeerToken(machineId: machine)
        settings.mirrorPeers[machine] = nil
        peerNotice = nil
    }
```

Refusing to paste this Mac's own connection: if `connection.machineId == MachineIdentity.stableId()`, set `peerNotice = "That is this Mac's own connection."` and return.

- [ ] **Step 2: Sidebar refusal overlay** gets a second button "Open Settings…". The Preferences window is SwiftUI's `Settings { … }` scene (`CanopyApp.swift:195`), so add `@Environment(\.openSettings) private var openSettings` to `Sidebar` and call `openSettings()` from the button.

- [ ] **Step 3: Build, run the probe (0 failed), then repeat Task 7's on-device steps 2-3 using the real Paste button.** Expected: the row lists studio's display name and address; Forget removes it and the next click on a studio row shows the "Paste … first" overlay with the Settings button.

- [ ] **Step 4: Commit**

```bash
git add Sources/Canopy/SettingsView.swift Sources/Canopy/Sidebar.swift
git commit -m "Pair other Macs from Settings › Mobile

- Paste Connection from Mac stores the address in settings and the
  password in the Keychain, and refuses this Mac's own connection
- Forget removes both; the sidebar's pairing refusal opens Settings

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Phone reads `live`; worker types record it

**Files (Canopy-Mobile repo, `~/repos/Personal/Canopy-Mobile`, on a new branch `roster-live-flag`):**
- Modify: `worker/src/types.ts` `PaneRow`
- Modify: `Sources/RosterModels.swift` `PaneRow`
- Modify: the Live button's enable predicate — grep `mirrorStore.target(for:` in `Sources/CanopyMobileApp.swift` (~line 635) and the view that draws the Live button
- Test: `Tests/` — find the existing `PaneRow` decode test (grep `PaneRow(` under `Tests/`) and add one case

- [ ] **Step 1: Failing test** — decode `{"sessionId":"s","paneIndex":0,"title":"","project":"","state":"idle","stateSince":0,"contextPct":0,"model":"","messageCount":0}` and assert `row.isLive == true`; decode the same with `"live":false` and assert `row.isLive == false`. Run with the repo's test scheme (`xcodebuild test -scheme CanopyMobile -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -20` or whatever `AGENTS.md` there prescribes). Expected: compile failure.

- [ ] **Step 2: Implement**

`RosterModels.swift`:

```swift
    /// Whether the Mac can accept an attach for this session right now. Nil
    /// from a Mac older than the flag, read as true so nothing changes there.
    let live: Bool?
    var isLive: Bool { live ?? true }
```

Add `live: Bool? = nil` to the memberwise call sites in `CanopyDemo.swift` (two places).

`types.ts`:

```ts
  /** True when the Mac runs a shim for this session, so an attach can
   *  succeed. Absent from a Mac older than the flag. The relay does not read
   *  it; recorded here because this file is the wire's documentation. */
  live?: boolean;
```

Live button: `.disabled(!pane.isLive)` on the button (keep the existing "This session is not open on the Mac." path for the rare race).

- [ ] **Step 3: Run the tests. Expected: PASS.**

- [ ] **Step 4: Commit in that repo**

```bash
git add worker/src/types.ts Sources/RosterModels.swift Sources/CanopyDemo.swift Sources/<the view file> Tests/<the test file>
git commit -m "Read the roster's live flag and disable Live when it is false

- live is optional and reads as true from a Mac that does not send it
- The relay is unchanged; types.ts records the field

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: CI floor, docs, and the findings list

**Files:**
- Modify: `.github/workflows/ci.yml` (`EXPECTED_ASSERTIONS`)
- Modify: `CLAUDE.md` (Key Source Files entries for `RemoteRosterWatcher.swift`, `MirrorClient.swift`, `MirrorPaneView.swift`; a "Key Learnings (Remote sessions in the sidebar)" section only if something was measured that the spec does not already say — otherwise a two-line pointer to the spec)
- Modify: `docs/superpowers/specs/2026-09-15-remote-sessions-sidebar-design.md` "見送り" list: add "mirror pane の context meter は空（`contextPct` は計算値で、roster の百分率を入れる口が無い）" plus anything new from the on-device runs; and in §4 change "`statusBar` の `model` / `contextPct` / `messageCount` も入れる" to name only `model` / `messageCount`

- [ ] **Step 1: Read the count off the finished branch**

`CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -1` → `--- N passed, 0 failed`. Write N into `EXPECTED_ASSERTIONS`. If `main` moved during this branch, rebase first and re-read; the number is measured, never summed.

- [ ] **Step 2: Mutation check, one at a time, restoring by `cp` (never `git checkout --`)**
  - Delete the `if case .mirror = session.origin { continue }` in `RosterSnapshot.rows` → `roster rows: a mirror session is never published` must FAIL.
  - Change `canOpen(.remoteLive)` to `true` → `remote rows: a stale row cannot open` and `a non-live row cannot open` must FAIL.
  - Change `remoteLiveSections`' `attached.contains` to `false` → `an attached session's row is dropped` must FAIL.
  Record the three results in the commit message.

- [ ] **Step 3: CLAUDE.md** — add the three file entries in the style of their neighbours (one bullet each, what it owns and the one non-obvious decision), and this line under SSH Remote's "Remaining Limitations" or a new short section: "Other Macs' live sessions: `docs/superpowers/specs/2026-09-15-remote-sessions-sidebar-design.md` — relay-fed list, TCP attach, `live` flag; the 見送り list there is the findings list." Check `CLAUDE.md -> AGENTS.md` symlink status before editing (edit the real file).

- [ ] **Step 4: Run the shim unit tests too** (`node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)`) — untouched, must still pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml CLAUDE.md docs/superpowers/specs/2026-09-15-remote-sessions-sidebar-design.md
git commit -m "Raise the probe floor and document the remote-sessions sidebar

- EXPECTED_ASSERTIONS measured on the finished branch
- Three mutations each turned exactly the assertion written for it red
- Key Source Files entries for the watcher, the mirror client and the
  mirror pane; the spec's 見送り list is the findings list

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage.** §1 relay as source → Task 5. §2 sidebar rows (placement, isOpen false, bypass the filter pipeline, hide attached, disabled + tooltip, stale dimming, no rename/hide, Copy Session ID, click routes) → Task 6. §3 watcher (gate, 5-min list, one socket per machine, decode rule, reconnect floor, 30 s ping, probe guard, no pause on hidden window) → Task 5. §4 attach (Origin.mirror, workingDirectory/home, localWorkingDirectory for Finder consumers, projectLabel, remoteHost nil, SessionContainer branch, MirrorPaneView built like buildWebView, OpenSession owns bridge, bridge out of DEBUG with outcomes, attach-before-load order, spawning→live on attach_ok, refusal → launcher banner with mapped messages, drop → overlay + Retry, state from roster, status bar machine name, no publish / no restore / no title store, duplicate attach focuses) → Tasks 1, 4, 7. §5 pairing (parse, settings + Keychain, list + Forget, unpaired click → message + Settings) → Tasks 3, 8. §6 roster all open sessions + `live` + `.mirror` excluded + probe; worker comment; phone optional + gate → Tasks 2, 9. Tests section → each task's probe block; on-device → Tasks 7, 8. CI floor + docs → Task 10. No gaps found.

**Placeholders.** None: every step has code or an exact command. Two "confirm before writing" notes (StatusBarData setters, `captureRestoreSnapshot` name) are lookups, not deferred work.

**Type consistency.** `RemoteLiveSession.sessionId` ↔ `attached` key `"\(machineId):\(sessionId)"` ↔ `openRemoteLive`'s match on `resumeId`: all three use the CLI id (`resumeId ?? sessionId`). `RosterSnapshot.Pane(… live:)` argument order: `live` is last everywhere. `RemoteMirrorBridge.Outcome` cases match between Task 4 and Task 7. `MirrorAccess.parseHostPort` is used by both `remoteAttachRefusal` and `openRemoteLive`.
