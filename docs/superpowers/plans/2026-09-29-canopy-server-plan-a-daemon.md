# Canopy Server Plan A — daemon モードと control API

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Canopy --daemon` として常駐し、Unix socket と Tailscale の両方で session の一覧・起動・停止・状態 push を提供する server 側を作る。

**Architecture:** 同じ binary を accessory アプリとして起動する daemon モードを足す。今の `MirrorServer`（attach、replay、asset、`open` 付き attach による headless 起動）をそのまま使い、最初の行が `hello` の接続を **control 接続**として扱う層（`ControlSession`）を足す。client 側（Canopy.app を client にする）は Plan B、phone は Plan C、削除は Plan D。

**Tech Stack:** Swift 6 / macOS 15、Network.framework（`NWListener`）、`ServiceManagement`（`SMAppService`）、xcodegen。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)

**実装は計画の後でレビューを受けて変わっている**（Debug の TCP ポート +1、Debug の登録は opt-in、Mirror が Off なら TCP なし、`startLocal -> Bool`、SIGTERM、`allowBypass`、`DaemonConfig` の読み直し ほか）。コードは PR #267 が正で、下のコード片は当時の計画のまま。

## Global Constraints

- Mac のみ。Xcode 26 toolchain でビルドする（CLAUDE.md「Tech Stack」）
- daemon は同じ binary の `--daemon` モード。別 target は作らない
- LaunchAgent であって LaunchDaemon ではない（login keychain のため）
- reaper の既定値は **15 分**。どの client も attach しておらず、working / asking でない状態が続いた時間で判定する
- Debug と Release は socket パスと LaunchAgent ラベルを bundle id で分ける（`sh.saqoo.Canopy` / `sh.saqoo.Canopy.debug`）
- local の Unix socket は 0600、token 不要。TCP は今の `MirrorAccess` の token 必須
- `protocolVersion` = 1。合わなければ `hello_error` を返して切る
- daemon は起動時に何も持ち越さない（session は全部 closed から始まる）
- `CANOPY_RUN_LOGIC_PROBE=1` の下では daemon を登録も起動もしない
- **コミットは Saqoosha が明示的に許可したときだけ**（`~/.claude/CLAUDE.md` Restricted Actions）。各タスクの Commit ステップは、許可が出ていなければ飛ばして差分を残す
- このリポジトリは jj-colocated だが、このワークツリーは git worktree で `.jj` が見えない。`git checkout -- <file>` で戻すと main の版で上書きされる。ファイルを戻すときは `cp` のバックアップを使う

## ビルドとテストのコマンド

```bash
cd /Users/hiko/.claude/worktrees/Canopy/canopy-server-architecture
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

probe は最後に `--- N passed, M failed` を出す。assertion は `_SidebarLogicProbe.swift` の `runAllTests()` の中で `record("name", condition)` を呼んで足す。assertion を足したら `.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS`（現在 1559）を、probe が出した passed の数に上げる。

## Review Focus

1. **daemon と GUI の Canopy が同じ Mac で同時に動く。** Plan A の間は GUI も自分の `MirrorServer` を Tailscale の `mirrorPort` で持っている。daemon の TCP は別の `daemonPort`（既定 8767）で listen し、衝突しない。Task 7 で probe 化できないので受け入れ手順で確かめる
2. **前回の daemon が残した socket ファイル。** クラッシュ後の再起動で `EADDRINUSE` になってはいけない。bind 前に古いファイルを消す（Task 4 に test）
3. **Recents にないフォルダ、存在しないフォルダ、ファイルを指す `open_session`。** 存在しない / ディレクトリでないものは `error` で答え、session を作らない（Task 5 に test）
4. **attach 中の session を reaper が止める。** client が 1 つでも attach していれば、何時間 idle でも止めない（Task 3 に test）
5. **socket パスの長さ。** Unix socket のパスは 104 バイトまで。ホームディレクトリが長いと bind が失敗する（Task 4 に test）

---

### Task 1: Unix socket の NWListener を実測する（spike、コードは残さない）

`NWListener` が `requiredLocalEndpoint = .unix(path:)` で listen できるかは未確認。Task 4 の前提なので最初に測る。

**Files:**
- Create（使い捨て）: `$SCRATCH/unix-listener-spike.swift`（`$SCRATCH` はセッションの scratchpad）

- [ ] **Step 1: spike を書く**

```swift
import Foundation
import Network

let path = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: path)
let params = NWParameters.tcp
params.requiredLocalEndpoint = .unix(path: path)
let listener = try NWListener(using: params)
listener.stateUpdateHandler = { print("listener:", $0) }
listener.newConnectionHandler = { conn in
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        print("got:", text.trimmingCharacters(in: .newlines))
        conn.send(content: Data("echo:\(text)".utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
listener.start(queue: .main)
dispatchMain()
```

- [ ] **Step 2: 走らせて nc で叩く**

```bash
swiftc -o $SCRATCH/spike $SCRATCH/unix-listener-spike.swift
$SCRATCH/spike $SCRATCH/t.sock &
SPIKE=$!
sleep 1
printf 'hello\n' | nc -U $SCRATCH/t.sock
kill $SPIKE
```

Expected: spike が `listener: ready` と `got: hello` を出し、nc が `echo:hello` を返す。

- [ ] **Step 3: 結果で分岐する**

- 通った → Task 4 は `NWListener` + `.unix(path:)` で書く（このまま）
- 通らない → **ここで止めて報告する。** Task 4 を POSIX socket + `DispatchSource` で書き直す必要があり、計画の改訂になる

---

### Task 2: control プロトコルの値型

**Files:**
- Create: `Sources/Canopy/ControlProtocol.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`（`runAllTests()` の中、`mirror recents:` の assertion 群のすぐ後に追加）
- Modify: `.github/workflows/ci.yml`（`EXPECTED_ASSERTIONS`）

**Interfaces:**
- Consumes: `RemoteDirectoryRules.newFolderNameProblem(_:) -> String?`、`RemoteDirectoryRules.childPath(of:name:) -> String`（`RemoteDirectoryBrowser.swift`）、`PermissionMode`（rawValue 付き enum）
- Produces:
  - `ControlProtocol.version: Int`（= 1）
  - `ControlProtocol.helloType = "hello"`
  - `ControlProtocol.HelloCheck`（`.ok` / `.unauthorized` / `.versionMismatch(client: Int, server: Int)`）
  - `ControlProtocol.checkHello(_ dict: [String: Any], trustsPeer: Bool, expectedToken: String?) -> HelloCheck`
  - `ControlProtocol.Request`（`id: String`、`verb: String`、`params: [String: Any]`）と `parseRequest(_:) -> Request?`
  - `ControlProtocol.response(id:result:) -> [String: Any]`、`errorResponse(id:message:) -> [String: Any]`
  - `ControlProtocol.DirEntry`（`name`, `isDirectory`）と `listDirectory(path:showHidden:) -> Result<[DirEntry], ControlError>`
  - `ControlProtocol.mkdir(parent:name:) -> Result<String, ControlError>`
  - `ControlProtocol.OpenParams` と `parseOpenParams(_:) -> Result<OpenParams, ControlError>`
  - `ControlProtocol.ControlError: Error, Equatable`（`message: String`）

- [ ] **Step 1: 失敗する assertion を書く**

`_SidebarLogicProbe.swift` の `runAllTests()` 内、`record("mirror recents: a relative folder and an id-less session are dropped", …)` の直後に足す:

```swift
            // Canopy Server control protocol (Plan A, Task 2).
            record("control hello: a local peer needs no token",
                   ControlProtocol.checkHello(["type": "hello", "protocolVersion": ControlProtocol.version],
                                              trustsPeer: true, expectedToken: nil) == .ok)
            record("control hello: a TCP peer with the right token passes",
                   ControlProtocol.checkHello(["type": "hello", "protocolVersion": ControlProtocol.version, "token": "abc"],
                                              trustsPeer: false, expectedToken: "abc") == .ok)
            record("control hello: a TCP peer with a wrong token is refused",
                   ControlProtocol.checkHello(["type": "hello", "protocolVersion": ControlProtocol.version, "token": "abd"],
                                              trustsPeer: false, expectedToken: "abc") == .unauthorized)
            record("control hello: a TCP peer with no token is refused even when none is configured",
                   ControlProtocol.checkHello(["type": "hello", "protocolVersion": ControlProtocol.version],
                                              trustsPeer: false, expectedToken: nil) == .unauthorized)
            record("control hello: another protocol version is refused with both numbers",
                   ControlProtocol.checkHello(["type": "hello", "protocolVersion": ControlProtocol.version + 1],
                                              trustsPeer: true, expectedToken: nil)
                       == .versionMismatch(client: ControlProtocol.version + 1, server: ControlProtocol.version))
            record("control hello: a missing version reads as 0, not as current",
                   ControlProtocol.checkHello(["type": "hello"], trustsPeer: true, expectedToken: nil)
                       == .versionMismatch(client: 0, server: ControlProtocol.version))
            let controlReq = ControlProtocol.parseRequest(["type": "request", "id": "r1", "verb": "list_folders", "params": ["limit": 5]])
            record("control request: id, verb and params parse",
                   controlReq?.id == "r1" && controlReq?.verb == "list_folders" && controlReq?.params["limit"] as? Int == 5)
            record("control request: a request without an id is rejected",
                   ControlProtocol.parseRequest(["type": "request", "verb": "list_folders"]) == nil)
            record("control request: absent params become empty",
                   ControlProtocol.parseRequest(["type": "request", "id": "r2", "verb": "subscribe"])?.params.isEmpty == true)
            record("control response: error carries id and message",
                   ControlProtocol.errorResponse(id: "r1", message: "nope")["id"] as? String == "r1"
                       && ControlProtocol.errorResponse(id: "r1", message: "nope")["error"] as? String == "nope")
            // listDirectory against a real fixture folder.
            let controlDir = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-control-probe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: controlDir.appendingPathComponent("zeta"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: controlDir.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: controlDir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: controlDir.appendingPathComponent("b.txt").path, contents: Data())
            defer { try? FileManager.default.removeItem(at: controlDir) }
            let listed = try? ControlProtocol.listDirectory(path: controlDir.path, showHidden: false).get()
            record("control browse: directories first, case-insensitive, hidden dropped",
                   listed?.map(\.name) == ["Alpha", "zeta", "b.txt"], "\(listed?.map(\.name) ?? [])")
            record("control browse: hidden shown on request",
                   (try? ControlProtocol.listDirectory(path: controlDir.path, showHidden: true).get())?.map(\.name).contains(".hidden") == true)
            record("control browse: a relative path is refused",
                   ControlProtocol.listDirectory(path: "relative", showHidden: false) == .failure(ControlProtocol.ControlError("path must be absolute")))
            record("control browse: a file is refused",
                   ControlProtocol.listDirectory(path: controlDir.appendingPathComponent("b.txt").path, showHidden: false)
                       == .failure(ControlProtocol.ControlError("not a folder")))
            let made = ControlProtocol.mkdir(parent: controlDir.path, name: "  new one  ")
            record("control mkdir: the trimmed name is created",
                   (try? made.get()) == controlDir.appendingPathComponent("new one").path
                       && FileManager.default.fileExists(atPath: controlDir.appendingPathComponent("new one").path))
            record("control mkdir: an existing folder is reported, not entered",
                   ControlProtocol.mkdir(parent: controlDir.path, name: "zeta") == .failure(ControlProtocol.ControlError("already exists")))
            record("control mkdir: a slash in the name is refused by the shared rule",
                   (try? ControlProtocol.mkdir(parent: controlDir.path, name: "a/b").get()) == nil)
            let openOK = ControlProtocol.parseOpenParams(["cwd": controlDir.path, "model": "opus", "permissionMode": "plan",
                                                          "initialPrompt": "hi", "worktreeBranch": "fix-x"])
            record("control open: all fields parse",
                   (try? openOK.get()) == ControlProtocol.OpenParams(cwd: controlDir.path, model: "opus", effort: nil,
                                                                     permissionMode: .plan, worktreeBranch: "fix-x", initialPrompt: "hi"))
            record("control open: a missing folder is refused before anything starts",
                   ControlProtocol.parseOpenParams(["cwd": controlDir.appendingPathComponent("nope").path])
                       == .failure(ControlProtocol.ControlError("not a folder")))
            record("control open: an unknown permission mode is refused, not defaulted",
                   ControlProtocol.parseOpenParams(["cwd": controlDir.path, "permissionMode": "yolo"])
                       == .failure(ControlProtocol.ControlError("unknown permission mode")))
```

- [ ] **Step 2: ビルドして失敗を確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: `cannot find 'ControlProtocol' in scope` でビルドが失敗する。

- [ ] **Step 3: 実装する**

`Sources/Canopy/ControlProtocol.swift`:

```swift
import Foundation

/// The Canopy Server control connection's wire shapes. Pure, so the probe
/// reaches every rule without a daemon, a socket or a shim.
///
/// A control connection is a `MirrorServer` connection whose first line is
/// `hello`. After `hello_ok`, the client sends `request` lines and gets one
/// `response` per id; after `subscribe` the server also pushes
/// `session_state` lines. See the spec's "API" section.
enum ControlProtocol {
    static let version = 1
    static let helloType = "hello"

    struct ControlError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    enum HelloCheck: Equatable {
        case ok
        case unauthorized
        case versionMismatch(client: Int, server: Int)
    }

    /// A local (Unix socket) peer is trusted by file permission; a TCP peer
    /// must present the mirror password. A TCP peer is refused when no
    /// password is configured at all, rather than let in.
    static func checkHello(_ dict: [String: Any], trustsPeer: Bool, expectedToken: String?) -> HelloCheck {
        if !trustsPeer {
            guard let provided = dict["token"] as? String, let expectedToken,
                  MirrorAccess.tokensMatch(provided, expectedToken) else { return .unauthorized }
        }
        // Absent means a client older than the field, which is not this version.
        let client = dict["protocolVersion"] as? Int ?? 0
        return client == version ? .ok : .versionMismatch(client: client, server: version)
    }

    struct Request {
        let id: String
        let verb: String
        let params: [String: Any]
    }

    static func parseRequest(_ dict: [String: Any]) -> Request? {
        guard dict["type"] as? String == "request",
              let id = dict["id"] as? String, !id.isEmpty,
              let verb = dict["verb"] as? String, !verb.isEmpty else { return nil }
        return Request(id: id, verb: verb, params: dict["params"] as? [String: Any] ?? [:])
    }

    static func response(id: String, result: Any) -> [String: Any] {
        ["type": "response", "id": id, "result": result]
    }

    static func errorResponse(id: String, message: String) -> [String: Any] {
        ["type": "response", "id": id, "error": message]
    }

    struct DirEntry: Equatable {
        let name: String
        let isDirectory: Bool
        var wire: [String: Any] { ["name": name, "isDirectory": isDirectory] }
    }

    /// Folders first, then files, each case-insensitively by name.
    static func listDirectory(path: String, showHidden: Bool) -> Result<[DirEntry], ControlError> {
        guard path.hasPrefix("/") else { return .failure(ControlError("path must be absolute")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(ControlError("not a folder"))
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            return .failure(ControlError("cannot read folder"))
        }
        let entries = children.compactMap { child -> DirEntry? in
            let name = child.lastPathComponent
            if !showHidden, name.hasPrefix(".") { return nil }
            let dir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return DirEntry(name: name, isDirectory: dir)
        }
        return .success(entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    /// Creates one folder. No `-p`: an existing folder is reported, the way
    /// `RemoteDirectoryBrowser`'s New Folder does.
    static func mkdir(parent: String, name: String) -> Result<String, ControlError> {
        let trimmed = RemoteDirectoryRules.trimmedName(name)
        if let problem = RemoteDirectoryRules.newFolderNameProblem(trimmed) { return .failure(ControlError(problem)) }
        let path = RemoteDirectoryRules.childPath(of: parent, name: trimmed)
        if FileManager.default.fileExists(atPath: path) { return .failure(ControlError("already exists")) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            return .failure(ControlError("cannot create folder"))
        }
        return .success(path)
    }

    struct OpenParams: Equatable {
        let cwd: String
        let model: String?
        let effort: String?
        let permissionMode: PermissionMode?
        let worktreeBranch: String?
        let initialPrompt: String?
    }

    static func parseOpenParams(_ params: [String: Any]) -> Result<OpenParams, ControlError> {
        guard let cwd = params["cwd"] as? String, cwd.hasPrefix("/") else {
            return .failure(ControlError("cwd must be absolute"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(ControlError("not a folder"))
        }
        var mode: PermissionMode?
        if let raw = params["permissionMode"] as? String {
            guard let parsed = PermissionMode(rawValue: raw) else { return .failure(ControlError("unknown permission mode")) }
            mode = parsed
        }
        func nonEmpty(_ key: String) -> String? {
            (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return .success(OpenParams(cwd: cwd, model: nonEmpty("model"), effort: nonEmpty("effort"),
                                   permissionMode: mode, worktreeBranch: nonEmpty("worktreeBranch"),
                                   initialPrompt: nonEmpty("initialPrompt")))
    }
}
```

`RemoteDirectoryRules.trimmedName` の実在は確認済み（`RemoteDirectoryBrowser.swift:346`）。`PermissionMode(rawValue:)` の raw 値が `"plan"` であることは Step 4 の assertion で確かめる。違ったら `AppState.swift` の `PermissionMode` の rawValue を見て assertion 側の文字列を合わせる。

- [ ] **Step 4: ビルドして probe を走らせる**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | grep -E "control |--- "`
Expected: `control ` で始まる 19 件が全部 PASS、`M failed` が 0。

- [ ] **Step 5: CI の floor を上げる**

probe の `--- N passed` の N を `.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS:` に書く。

- [ ] **Step 6: Commit（許可があれば）**

```bash
git add Sources/Canopy/ControlProtocol.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Add Canopy Server control protocol value types"
```

---

### Task 3: reaper の判定

**Files:**
- Create: `Sources/Canopy/SessionReaper.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`（Task 2 の assertion の直後）
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `SessionReaper.defaultIdleLimit: TimeInterval`（= 900）
  - `SessionReaper.Inputs`（`attachedClients: Int`, `isBusy: Bool`, `quietSince: Date`）
  - `SessionReaper.shouldReap(_ inputs: Inputs, now: Date, limit: TimeInterval) -> Bool`

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            // Canopy Server reaper (Plan A, Task 3).
            let reapT0 = Date(timeIntervalSince1970: 2_000_000)
            let reapLimit = SessionReaper.defaultIdleLimit
            func reapInputs(clients: Int, busy: Bool, quietFor: TimeInterval) -> SessionReaper.Inputs {
                SessionReaper.Inputs(attachedClients: clients, isBusy: busy, quietSince: reapT0.addingTimeInterval(-quietFor))
            }
            record("reaper: the default limit is 15 minutes", reapLimit == 15 * 60)
            record("reaper: quiet exactly the limit with no client is reaped",
                   SessionReaper.shouldReap(reapInputs(clients: 0, busy: false, quietFor: reapLimit), now: reapT0, limit: reapLimit))
            record("reaper: one second short of the limit is kept",
                   !SessionReaper.shouldReap(reapInputs(clients: 0, busy: false, quietFor: reapLimit - 1), now: reapT0, limit: reapLimit))
            record("reaper: an attached client keeps it however long it is quiet",
                   !SessionReaper.shouldReap(reapInputs(clients: 1, busy: false, quietFor: 24 * 3600), now: reapT0, limit: reapLimit))
            record("reaper: a busy session is kept however long nobody watches",
                   !SessionReaper.shouldReap(reapInputs(clients: 0, busy: true, quietFor: 24 * 3600), now: reapT0, limit: reapLimit))
            record("reaper: a quietSince in the future (clock change) is kept",
                   !SessionReaper.shouldReap(reapInputs(clients: 0, busy: false, quietFor: -60), now: reapT0, limit: reapLimit))
```

- [ ] **Step 2: ビルドして失敗を確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: `cannot find 'SessionReaper' in scope`。

- [ ] **Step 3: 実装する**

`Sources/Canopy/SessionReaper.swift`:

```swift
import Foundation

/// When the daemon stops a session nobody is using. Stopping is cheap to
/// undo — an `attach` resumes it — and a running shim (node + CLI) costs
/// hundreds of MB, so the limit is short. See the spec's "session のライフサイクル".
enum SessionReaper {
    static let defaultIdleLimit: TimeInterval = 15 * 60

    struct Inputs: Equatable {
        /// Clients attached to this session right now.
        let attachedClients: Int
        /// Working, waiting on a permission decision, or waiting on an
        /// AskUserQuestion answer. Stopping those loses a turn or a question.
        let isBusy: Bool
        /// The later of: the last client detaching, the last turn ending.
        let quietSince: Date
    }

    static func shouldReap(_ inputs: Inputs, now: Date, limit: TimeInterval) -> Bool {
        guard inputs.attachedClients == 0, !inputs.isBusy else { return false }
        return now.timeIntervalSince(inputs.quietSince) >= limit
    }
}
```

- [ ] **Step 4: ビルドして probe**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | grep -E "reaper: |--- "`
Expected: `reaper:` 6 件 PASS、failed 0。

- [ ] **Step 5: CI の floor を上げる**（Task 2 Step 5 と同じ手順）

- [ ] **Step 6: Commit（許可があれば）**

```bash
git add Sources/Canopy/SessionReaper.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Add the daemon's idle-session reaper rule"
```

---

### Task 4: `MirrorServer` に local の Unix socket listener を足す

**Files:**
- Create: `Sources/Canopy/DaemonPaths.swift`
- Modify: `Sources/Canopy/MirrorServer.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `DaemonPaths.socketPath(bundleId: String, home: URL) -> String`
  - `DaemonPaths.maxSocketPathBytes: Int`（= 103。`sun_path` 104 バイトから終端 NUL を引いた数）
  - `DaemonPaths.current: String`（`Bundle.main.bundleIdentifier` とホームから作る）
  - `MirrorServer.startLocal(socketPath: String)`、`MirrorServer.stopLocal()`
  - `MirrorConnection.trustsPeer: Bool`（local listener から来た接続だけ true）

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            // Canopy Server socket path (Plan A, Task 4).
            let probeHome = URL(fileURLWithPath: "/Users/someone")
            let releaseSock = DaemonPaths.socketPath(bundleId: "sh.saqoo.Canopy", home: probeHome)
            let debugSock = DaemonPaths.socketPath(bundleId: "sh.saqoo.Canopy.debug", home: probeHome)
            record("daemon socket: Debug and Release never share a path", releaseSock != debugSock)
            record("daemon socket: lives under Application Support/Canopy",
                   releaseSock.hasPrefix("/Users/someone/Library/Application Support/Canopy/"))
            record("daemon socket: fits sun_path for an ordinary home",
                   debugSock.utf8.count <= DaemonPaths.maxSocketPathBytes, "\(debugSock.utf8.count)")
            let longHome = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 80))
            record("daemon socket: an over-long home falls back to a short path under /tmp",
                   DaemonPaths.socketPath(bundleId: "sh.saqoo.Canopy.debug", home: longHome).utf8.count <= DaemonPaths.maxSocketPathBytes)
```

- [ ] **Step 2: ビルドして失敗を確かめる**

Expected: `cannot find 'DaemonPaths' in scope`。

- [ ] **Step 3: `DaemonPaths` を実装する**

`Sources/Canopy/DaemonPaths.swift`:

```swift
import Foundation

/// Where the daemon's local socket lives. Keyed by bundle id because
/// `~/Library/Application Support/Canopy` is shared by Debug and Release
/// (CLAUDE.md, entry-file learning): one path would let a Debug daemon
/// take the Release app's socket.
enum DaemonPaths {
    /// `sun_path` is 104 bytes on Darwin, NUL included.
    static let maxSocketPathBytes = 103

    static func socketPath(bundleId: String, home: URL) -> String {
        let preferred = home
            .appendingPathComponent("Library/Application Support/Canopy", isDirectory: true)
            .appendingPathComponent("daemon-\(bundleId).sock").path
        if preferred.utf8.count <= maxSocketPathBytes { return preferred }
        // Per-user so two accounts on one Mac do not collide; getuid keeps it short.
        return "/tmp/canopy-\(getuid())-\(bundleId).sock"
    }

    static var current: String {
        socketPath(bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy",
                   home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
```

- [ ] **Step 4: `MirrorServer` に local listener を足す**

`MirrorServer.swift` の `MirrorServer` クラスに、`listener` の隣へ追加:

```swift
    private var localListener: NWListener?
    private var localSocketPath: String?

    /// The daemon's own socket. Trusted by file permission (0600), so a
    /// connection from it needs no password.
    func startLocal(socketPath: String) {
        stopLocal()
        // A crashed daemon leaves its socket file; binding over it fails with EADDRINUSE.
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socketPath)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.localListener === listener else { return }
                    switch state {
                    case .ready:
                        chmod(socketPath, 0o600)
                        logger.notice("[mirror-server] local socket ready")
                    case .waiting(let error), .failed(let error):
                        logger.error("[mirror-server] local socket cannot bind: \(error.localizedDescription, privacy: .public)")
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, trustsPeer: true) }
            }
            listener.start(queue: .main)
            localListener = listener
            localSocketPath = socketPath
        } catch {
            logger.error("[mirror-server] local socket start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopLocal() {
        localListener?.cancel()
        localListener = nil
        if let path = localSocketPath { try? FileManager.default.removeItem(atPath: path) }
        localSocketPath = nil
    }
```

`accept` を置き換える:

```swift
    private func accept(_ connection: NWConnection, trustsPeer: Bool = false) {
        let mirror = MirrorConnection(connection: connection, store: store, server: self, trustsPeer: trustsPeer)
        connections.append(mirror)
        mirror.start()
    }
```

`MirrorConnection` にプロパティと init 引数を足す:

```swift
    /// True for a connection from the daemon's local Unix socket, which the
    /// file mode already restricts to this user. Every password check below
    /// passes for it.
    let trustsPeer: Bool
```

```swift
    init(connection: NWConnection, store: SessionStore, server: MirrorServer, trustsPeer: Bool) {
        self.connection = connection
        self.store = store
        self.server = server
        self.trustsPeer = trustsPeer
    }
```

`answerRecents` と `handleAttach` の password 検査を、それぞれ次の形に置き換える（2 箇所）:

```swift
        guard trustsPeer || {
            guard let provided = dict["token"] as? String, let expected = server?.token else { return false }
            return MirrorAccess.tokensMatch(provided, expected)
        }()
        else {
```

（`else` 以下のログと `failAttach("unauthorized")` はそのまま残す。）

`ControlSession` が token を読めるよう、`token` の宣言を `fileprivate var token` から次へ変える:

```swift
    /// Read once per bind so an attach never touches the Keychain; `resetPassword` replaces it.
    private(set) var token: String
```

`resetPassword` の中の `current?.token = token` は同じ型の中なので `private(set)` のままで書ける。

- [ ] **Step 5: ビルドして probe**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | grep -E "daemon socket: |--- "`
Expected: `daemon socket:` 4 件 PASS、failed 0。

- [ ] **Step 6: CI の floor を上げる**

- [ ] **Step 7: Commit（許可があれば）**

```bash
git add Sources/Canopy/DaemonPaths.swift Sources/Canopy/MirrorServer.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Let MirrorServer listen on a trusted local Unix socket"
```

---

### Task 5: control 接続（`ControlSession`）

**Files:**
- Create: `Sources/Canopy/ControlSession.swift`
- Modify: `Sources/Canopy/MirrorServer.swift`（`handleLineData` と `handleAttach` の振り分け）
- Modify: `Sources/Canopy/SessionStore.swift`（`startHeadlessSession(directory:…)` に起動オプションを足す）

**Interfaces:**
- Consumes: Task 2 の `ControlProtocol` 全部、Task 4 の `MirrorConnection.trustsPeer` と `MirrorServer.token`、`SessionStore.startHeadlessSession`、`SessionStore.closeSession(_:keepingFailure:)`、`SessionStore.refreshRecents() async`、`SessionStore.recents`、`SessionStore.hiddenIds`、`RecentDirectories.load()`、`SessionActivity.of(_:isUnread:)`、`RosterSnapshot.wireState(for:)`、`MachineIdentity.stableId()`、`GitWorktree.createWorktree(repo:branch:baseRef:)`、`GitWorktree.defaultBaseRef(for:)`、`LaunchPrompt.make(text:images:)`
- Produces:
  - `ControlSession(store: SessionStore, send: @escaping ([String: Any]) -> Void)`、`handle(_ dict: [String: Any])`、`stop()`
  - `SessionStore.HeadlessOptions`（`model`, `effort`, `permissionMode`, `initialPrompt`）
  - `SessionStore.startHeadlessSession(directory:resumeId:isExistingTranscript:title:options:)`（`options` は既定値 `.init()`）
  - wire: `hello_ok {protocolVersion, machineId}`、`hello_error {message}`、`response`、`session_state {sessions: [row]}`
  - session row の wire: `{"id": resumeId, "title", "project", "cwd", "state": wireState, "running": Bool, "clients": Int, "lastActiveAt": epoch秒}`

- [ ] **Step 1: `SessionStore` に起動オプションを足す**

`SessionStore.swift` の `startHeadlessSession(directory:resumeId:isExistingTranscript:title:)` を置き換える:

```swift
    /// What a control `open_session` can set on a new headless session.
    struct HeadlessOptions {
        var model: String? = nil
        var effort: String? = nil
        var permissionMode: PermissionMode? = nil
        var initialPrompt: String? = nil
    }

    func startHeadlessSession(directory: URL, resumeId: String, isExistingTranscript: Bool, title: String?,
                              options: HeadlessOptions = .init()) -> ShimProcess? {
        if openSessions.contains(where: { $0.resumeId == resumeId }) {
            return startHeadlessSession(resumeId: resumeId)
        }
        let provider = ModelProviderStore.selectedProvider()
        let accountChoice = launchAccountChoice(customApi: provider)
        let session = OpenSession(
            origin: .local(directory),
            resumeId: resumeId,
            title: title ?? "Untitled",
            project: GitWorktree.projectDisplayName(for: directory),
            status: .dormant,
            permissionMode: options.permissionMode ?? CanopySettings.shared.defaultPermissionMode,
            customApi: provider,
            claudeAccount: accountChoice.account,
            resumeIdIsExistingTranscript: isExistingTranscript
        )
        session.model = options.model
        session.effortLevel = options.effort
        // Sent by the launch_claude intercept, i.e. once the first client's
        // webview attaches — a headless session has no webview of its own.
        if let text = options.initialPrompt { session.pendingInitialPrompt = LaunchPrompt.make(text: text, images: []) }
        session.accountAutoSwitch = accountChoice.autoSwitch
        openSessions.append(session)
        guard let shim = startHeadlessSession(resumeId: resumeId) else {
            // Nobody here asked for this row; a failed start must not leave it behind.
            openSessions.removeAll { $0.id == session.id }
            return nil
        }
        if !isExistingTranscript { RecentDirectories.add(directory) }
        return shim
    }
```

（`OpenSession` の `init` が `model:` / `effortLevel:` を引数で取るなら、後から代入せず引数で渡す。`OpenSession.swift` の init を確認してから決める。）

- [ ] **Step 2: `ControlSession` を書く**

`Sources/Canopy/ControlSession.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlSession")

/// One client's control connection to the daemon, after `hello`.
/// Requests are answered one `response` per id; `subscribe` adds
/// `session_state` pushes whenever an open session's row changes.
@MainActor
final class ControlSession {
    private let store: SessionStore
    private let send: ([String: Any]) -> Void
    private var subscribed = false
    private var lastPushed: [[String: String]] = []
    private var stopped = false

    init(store: SessionStore, send: @escaping ([String: Any]) -> Void) {
        self.store = store
        self.send = send
    }

    func stop() { stopped = true }

    func handle(_ dict: [String: Any]) {
        guard let request = ControlProtocol.parseRequest(dict) else {
            logger.error("control: unreadable request (type=\(dict["type"] as? String ?? "nil", privacy: .public))")
            return
        }
        switch request.verb {
        case "list_sessions": listSessions(request)
        case "list_folders": listFolders(request)
        case "browse_dir": browse(request)
        case "mkdir": makeFolder(request)
        case "open_session": openSession(request)
        case "stop_session": stopSession(request)
        case "subscribe":
            reply(request, ["ok": true])
            if !subscribed { subscribed = true; trackOpenSessions() }
        default:
            fail(request, "unknown verb")
        }
    }

    // MARK: - Verbs

    private func listSessions(_ request: ControlProtocol.Request) {
        let limit = request.params["limit"] as? Int ?? 50
        switch request.params["scope"] as? String ?? "open" {
        case "open":
            reply(request, ["sessions": Array(openRows().prefix(limit))])
        case "recent":
            Task { @MainActor in
                await store.refreshRecents()
                guard !stopped else { return }
                let open = Set(store.openSessions.map(\.resumeId))
                let query = (request.params["query"] as? String ?? "").lowercased()
                let rows = store.recents
                    .filter { $0.canOpen && !open.contains($0.id) && !store.hiddenIds.contains($0.id) }
                    .filter { query.isEmpty || $0.title.lowercased().contains(query) || $0.projectName.lowercased().contains(query) }
                    .prefix(limit)
                    .map { ["id": $0.id, "title": $0.title, "project": $0.projectName,
                            "cwd": $0.projectDirectory.path, "state": "closed", "running": false, "clients": 0,
                            "lastActiveAt": $0.timestamp.timeIntervalSince1970] as [String: Any] }
                reply(request, ["sessions": Array(rows)])
            }
        default:
            fail(request, "unknown scope")
        }
    }

    private func listFolders(_ request: ControlProtocol.Request) {
        let limit = request.params["limit"] as? Int ?? 20
        let folders = RecentDirectories.load().filter { FileManager.default.fileExists(atPath: $0.path) }
        reply(request, ["folders": folders.prefix(limit).map(\.path)])
    }

    private func browse(_ request: ControlProtocol.Request) {
        let path = request.params["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        switch ControlProtocol.listDirectory(path: path, showHidden: request.params["showHidden"] as? Bool == true) {
        case .success(let entries): reply(request, ["path": path, "entries": entries.map(\.wire)])
        case .failure(let error): fail(request, error.message)
        }
    }

    private func makeFolder(_ request: ControlProtocol.Request) {
        guard let parent = request.params["parent"] as? String, let name = request.params["name"] as? String else {
            fail(request, "parent and name are required")
            return
        }
        switch ControlProtocol.mkdir(parent: parent, name: name) {
        case .success(let path): reply(request, ["path": path])
        case .failure(let error): fail(request, error.message)
        }
    }

    private func openSession(_ request: ControlProtocol.Request) {
        let params: ControlProtocol.OpenParams
        switch ControlProtocol.parseOpenParams(request.params) {
        case .success(let parsed): params = parsed
        case .failure(let error):
            fail(request, error.message)
            return
        }
        var directory = URL(fileURLWithPath: params.cwd, isDirectory: true)
        if let branch = params.worktreeBranch {
            do {
                directory = try GitWorktree.createWorktree(repo: directory, branch: branch,
                                                           baseRef: GitWorktree.defaultBaseRef(for: directory))
            } catch {
                logger.error("control open_session: worktree failed: \(error.localizedDescription, privacy: .public)")
                fail(request, "worktree failed: \(error.localizedDescription)")
                return
            }
        }
        // A placeholder the CLI's own id replaces once a client's webview launches it;
        // the client attaches with this id right away, so the swap is invisible to it.
        let sessionId = UUID().uuidString.lowercased()
        let options = SessionStore.HeadlessOptions(model: params.model, effort: params.effort,
                                                   permissionMode: params.permissionMode,
                                                   initialPrompt: params.initialPrompt)
        guard store.startHeadlessSession(directory: directory, resumeId: sessionId, isExistingTranscript: false,
                                         title: nil, options: options) != nil else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["sessionId": sessionId, "cwd": directory.path])
    }

    private func stopSession(_ request: ControlProtocol.Request) {
        guard let sessionId = request.params["sessionId"] as? String,
              let session = store.openSessions.first(where: { $0.resumeId == sessionId }) else {
            fail(request, "no such session")
            return
        }
        store.closeSession(session.id, keepingFailure: false)
        reply(request, ["ok": true])
    }

    // MARK: - subscribe

    private func openRows() -> [[String: Any]] {
        store.openSessions.map { session in
            let activity = SessionActivity.of(session, isUnread: store.unreadSessionIds.contains(session.id))
            return ["id": session.resumeId, "title": session.title, "project": session.project,
                    "cwd": session.origin.workingDirectory.path,
                    "state": RosterSnapshot.wireState(for: activity),
                    "running": session.shim?.isLive == true,
                    "clients": session.shim?.mirrorCount ?? 0,
                    "lastActiveAt": session.lastActiveAt.timeIntervalSince1970]
        }
    }

    /// Re-armed from its own `onChange`, one tracker at a time, like
    /// `AppDelegate.trackMirrorSettings`. Pushes only when a row's
    /// id/title/state/clients actually changed.
    private func trackOpenSessions() {
        guard !stopped else { return }
        let rows = withObservationTracking {
            openRows()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackOpenSessions() } }
        }
        let signature = rows.map { row in
            ["id": row["id"] as? String ?? "", "title": row["title"] as? String ?? "",
             "state": row["state"] as? String ?? "", "clients": "\(row["clients"] as? Int ?? 0)",
             "running": "\(row["running"] as? Bool ?? false)"]
        }
        guard signature != lastPushed else { return }
        lastPushed = signature
        send(["type": "session_state", "sessions": rows])
    }

    // MARK: - Replies

    private func reply(_ request: ControlProtocol.Request, _ result: [String: Any]) {
        guard !stopped else { return }
        send(ControlProtocol.response(id: request.id, result: result))
    }

    private func fail(_ request: ControlProtocol.Request, _ message: String) {
        guard !stopped else { return }
        logger.notice("control \(request.verb, privacy: .public) refused: \(message, privacy: .public)")
        send(ControlProtocol.errorResponse(id: request.id, message: message))
    }
}
```

注意点を 2 つ。
- `SessionEntry` のプロパティ名（`projectName`, `projectDirectory`, `timestamp`, `canOpen`）は `MirrorServer.answerRecents` と `MirrorRecents.replyPayload` が使っているものと同じ。
- `session.lastActiveAt`、`session.origin.workingDirectory` は `OpenSession` に実在する（CLAUDE.md の `OpenSession.swift` の記述、`startHeadlessSession(resumeId:)` の使い方）。`shim.mirrorCount` は Task 6 で足す。**Task 5 のビルドは Task 6 の Step 1 まで通らない**ので、Task 6 の Step 1 を先に入れてからビルドする。

- [ ] **Step 3: `MirrorConnection` から control へ振り分ける**

`MirrorConnection` にプロパティを足す:

```swift
    /// Set once the first line was `hello`; every later line goes here instead of to a shim.
    private var control: ControlSession?
```

`handleLineData` の `if !didAttach {` の前に入れる:

```swift
        if let control {
            control.handle(dict)
            return
        }
```

`handleAttach` の先頭（`MirrorRecents.listType` の判定の前）に入れる:

```swift
        if dict["type"] as? String == ControlProtocol.helloType {
            switch ControlProtocol.checkHello(dict, trustsPeer: trustsPeer, expectedToken: server?.token) {
            case .ok:
                let session = ControlSession(store: store) { [weak self] payload in self?.sendJSONObject(payload) }
                control = session
                didAttach = true
                compressOutbound = dict["compress"] as? String == MirrorWire.compressionName
                sendJSONObject(["type": "hello_ok", "protocolVersion": ControlProtocol.version,
                                "machineId": MachineIdentity.stableId() ?? ""])
                logger.notice("[mirror-server] control connection opened (local=\(self.trustsPeer))")
            case .unauthorized:
                logger.error("[mirror-server] hello refused: wrong or missing password")
                failHello("unauthorized")
            case .versionMismatch(let client, let server):
                logger.error("[mirror-server] hello refused: protocol \(client) vs \(server)")
                failHello("protocol version \(client) is not \(server)")
            }
            return
        }
```

`failAttach` の隣に足す（`attach_error` ではなく `hello_error` を送る以外は同じ）:

```swift
    private func failHello(_ message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "hello_error", "message": message])) ?? Data()
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        cleanup()
    }
```

`cleanup()` の先頭（`statusPublisher?.stop()` の前）に足す:

```swift
        control?.stop()
        control = nil
```

- [ ] **Step 4: ビルドする（Task 6 Step 1 を入れた後）**

Run: `./scripts/build_debug_stable.sh`
Expected: 成功。

- [ ] **Step 5: Commit（許可があれば、Task 6 と一緒でよい）**

```bash
git add Sources/Canopy/ControlSession.swift Sources/Canopy/MirrorServer.swift Sources/Canopy/SessionStore.swift
git commit -m "Add the daemon control connection and its verbs"
```

---

### Task 6: reaper を shim と daemon に配線する

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift`
- Create: `Sources/Canopy/DaemonReaper.swift`

**Interfaces:**
- Consumes: Task 3 の `SessionReaper`、`SessionStore.closeSession(_:keepingFailure:)`
- Produces:
  - `ShimProcess.mirrorCount: Int`
  - `ShimProcess.reaperInputs: SessionReaper.Inputs`
  - `DaemonReaper(store: SessionStore, limit: TimeInterval)`、`start()`、`stop()`

- [ ] **Step 1: `ShimProcess` に読み口を足す**

`private var mirrors: [ObjectIdentifier: MirrorClient] = [:]`（92 行目付近）の直後に:

```swift
    /// Clients attached besides the primary webview. The daemon has no
    /// primary, so for it this is every client.
    var mirrorCount: Int { mirrors.count }

    /// When this session last became quiet: the last client detaching or the
    /// last turn ending, whichever is later. Read by `DaemonReaper`.
    private(set) var quietSince = Date()

    var reaperInputs: SessionReaper.Inputs {
        SessionReaper.Inputs(
            attachedClients: mirrors.count + (webView == nil ? 0 : 1),
            isBusy: isWorking || !pendingPermissionRequestIds.isEmpty || lastAssistantHadAskUserQuestion,
            quietSince: quietSince)
    }
```

`detachMirror(_:)`（173 行目付近）の本体の最後に:

```swift
        if mirrors.isEmpty { quietSince = Date() }
```

`isWorking` の宣言（411 行目付近、`private var isWorking = false {`）の `didSet` の中に足す（`didSet` が無ければ作る。既存の `didSet` があればその先頭に）:

```swift
            if oldValue, !isWorking { quietSince = Date() }
```

`lastAssistantHadAskUserQuestion` と `pendingPermissionRequestIds` は同じクラス内の private なので、そのまま読める。名前が違っていたら `grep -n "lastAssistantHadAskUserQuestion" Sources/Canopy/ShimProcess.swift` で確認する（1170 行目で使われている）。

- [ ] **Step 2: `DaemonReaper` を書く**

`Sources/Canopy/DaemonReaper.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonReaper")

/// Stops daemon sessions nobody is using (`SessionReaper`). Daemon mode
/// only: in the GUI app a session with a pane has a primary webview and
/// `reaperInputs` already counts it as attached, but the app never starts this.
@MainActor
final class DaemonReaper {
    private let store: SessionStore
    private let limit: TimeInterval
    private var timer: Timer?

    init(store: SessionStore, limit: TimeInterval = SessionReaper.defaultIdleLimit) {
        self.store = store
        self.limit = limit
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        for session in store.openSessions {
            guard let shim = session.shim, SessionReaper.shouldReap(shim.reaperInputs, now: now, limit: limit) else { continue }
            logger.notice("reaping \(session.resumeId, privacy: .public): quiet \(Int(now.timeIntervalSince(shim.reaperInputs.quietSince)))s with no client")
            store.closeSession(session.id, keepingFailure: false)
        }
    }
}
```

- [ ] **Step 3: ビルドする**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1`
Expected: ビルド成功、probe の failed 0。

- [ ] **Step 4: Commit（許可があれば）**

```bash
git add Sources/Canopy/ShimProcess.swift Sources/Canopy/DaemonReaper.swift
git commit -m "Wire the idle reaper to shim state"
```

---

### Task 7: daemon モードの起動

**Files:**
- Create: `Sources/Canopy/CanopyMain.swift`
- Create: `Sources/Canopy/CanopyDaemon.swift`
- Modify: `Sources/Canopy/CanopyApp.swift`（`@main` を外す）
- Modify: `Sources/Canopy/CanopySettings.swift`（`daemonPort` を足す）

**Interfaces:**
- Consumes: Task 4 の `MirrorServer.startLocal(socketPath:)`、`DaemonPaths.current`、Task 6 の `DaemonReaper`、`MirrorAccess.tailscaleIPv4()`、`MirrorAccess.token(createIfMissing:)`、`KeepAliveCoordinator.shared.start()`、`SessionStore()`、`SessionStore.refreshRecents()`
- Produces:
  - `CanopyMain`（`@main`）。`--daemon` があれば `CanopyDaemon.run()`、なければ `CanopyApp.main()`
  - `CanopyDaemon.run() -> Never`
  - `CanopySettings.daemonPort: Int`（既定 8767）

- [ ] **Step 1: `daemonPort` を足す**

`CanopySettings.swift` で `mirrorPort` が定義・読み込み・保存されている 3 箇所を見て、同じ形で `daemonPort`（既定 8767、キー `canopy.daemonPort`）を足す。Plan A の間は GUI の `MirrorServer` が `mirrorPort` を使い続けるので、daemon は別ポートにする。Plan B で GUI の listener を消すときに 1 つにまとめる。

- [ ] **Step 2: エントリポイントを分ける**

`CanopyApp.swift` 9 行目の `@main` を削除する。

`Sources/Canopy/CanopyMain.swift`:

```swift
import SwiftUI

/// Chooses between the GUI app and the daemon before either touches
/// NSApplication. `CanopyApp.main()` is SwiftUI's own entry; the daemon
/// never builds a scene, so it must branch here rather than inside the App.
@main
enum CanopyMain {
    static func main() {
        // `main` runs on the main thread; both entries are main-actor isolated.
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--daemon") {
                CanopyDaemon.run()
            } else {
                CanopyApp.main()
            }
        }
    }
}
```

- [ ] **Step 3: daemon 本体を書く**

`Sources/Canopy/CanopyDaemon.swift`:

```swift
import AppKit
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopyDaemon")

/// `Canopy --daemon`: an accessory app with no windows that owns sessions and
/// serves them over the local socket and Tailscale. See the spec's
/// "プロセスの境界".
@MainActor
enum CanopyDaemon {
    private static var delegate: DaemonDelegate?

    static func run() -> Never {
        #if DEBUG
        // The probe runs in the GUI entry; a daemon must never start under it.
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { exit(0) }
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = DaemonDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
final class DaemonDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var server: MirrorServer?
    private var reaper: DaemonReaper?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("daemon starting pid=\(getpid())")
        Task { await store.refreshRecents() }
        KeepAliveCoordinator.shared.start()

        let token = MirrorAccess.token(createIfMissing: true) ?? ""
        let server = MirrorServer(store: store, token: token)
        self.server = server
        server.startLocal(socketPath: DaemonPaths.current)
        startTCP(server)

        let reaper = DaemonReaper(store: store)
        self.reaper = reaper
        reaper.start()
    }

    /// Tailscale may come up after login; retry until it has an address.
    private func startTCP(_ server: MirrorServer) {
        guard let port = UInt16(exactly: CanopySettings.shared.daemonPort), port != 0 else { return }
        guard let host = MirrorAccess.tailscaleIPv4() else {
            logger.notice("no Tailscale address yet; retrying in 30 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated { self?.startTCP(server) }
            }
            return
        }
        server.start(host: host, port: port)
    }

    func applicationWillTerminate(_ notification: Notification) {
        reaper?.stop()
        server?.stop()
        server?.stopLocal()
        for session in store.openSessions { session.shim?.stop() }
    }
}
```

`MirrorServer.start(host:port:)` は `MirrorServerStatus.shared.state` を書く。daemon では誰も読まないので害はない。

`KeepAliveCoordinator` は pane を走査する（CLAUDE.md の keep-alive learnings）。daemon には pane が無いので、何もしない。「attach している client がいる session」を対象にするのは Plan B で行う（spec の「keep-alive の対象」）。**ここでは `start()` を呼ぶだけにして、対象の切り替えはしない。**

- [ ] **Step 4: ビルドして daemon を手で起動する**

```bash
./scripts/build_debug_stable.sh
./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --daemon &
DAEMON=$!
sleep 3
SOCK="$HOME/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock"
ls -l "$SOCK"
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' \
    '{"type":"request","id":"1","verb":"list_folders"}' \
    '{"type":"request","id":"2","verb":"browse_dir","params":{"path":"/tmp"}}' \
    '{"type":"request","id":"3","verb":"list_sessions","params":{"scope":"recent","limit":3}}'
  sleep 3; } | nc -U "$SOCK"
kill $DAEMON
```

Expected:
- `ls` が `srw-------` を出す（0600）
- nc の出力 1 行目が `hello_ok`、続いて id 1〜3 の `response` が各 1 行
- window が 1 枚も開かない。Dock にアイコンが出ない

- [ ] **Step 5: open_session と attach を手で通す**

```bash
./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --daemon &
DAEMON=$!
sleep 3
SOCK="$HOME/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock"
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' \
    '{"type":"request","id":"1","verb":"subscribe"}' \
    "{\"type\":\"request\",\"id\":\"2\",\"verb\":\"open_session\",\"params\":{\"cwd\":\"$SCRATCH\"}}"
  sleep 8; } | nc -U "$SOCK"
```

Expected: id 2 の `response` に `sessionId` がある。`session_state` が少なくとも 1 回、その session を `"running": true` で含んで push される。

同じ daemon のまま、別の nc で attach する（`<ID>` は上の sessionId）:

```bash
{ printf '%s\n' '{"type":"attach","sessionId":"<ID>","client":"mac"}'; sleep 3; } | nc -U "$SOCK" | head -c 300
kill $DAEMON
```

Expected: 1 行目が `{"type":"attach_ok",…`（local なので token なしで通る）。

- [ ] **Step 6: Commit（許可があれば）**

```bash
git add Sources/Canopy/CanopyMain.swift Sources/Canopy/CanopyDaemon.swift Sources/Canopy/CanopyApp.swift Sources/Canopy/CanopySettings.swift
git commit -m "Add Canopy --daemon mode"
```

---

### Task 8: LaunchAgent として登録する

spec の未決「`SMAppService` の登録をいつ承認してもらうか」は、ここで **GUI の Canopy が起動するたびに登録を確認する** と決める。登録済みなら何もしない。macOS が初回に「ログイン項目に追加されました」の通知を出すので、ユーザは System Settings から外せる。承認待ち（`.requiresApproval`）のときは Plan A ではログだけ出す。UI は Plan B。

**Files:**
- Create: `Resources/LaunchAgents/sh.saqoo.Canopy.daemon.plist`
- Create: `Resources/LaunchAgents/sh.saqoo.Canopy.debug.daemon.plist`
- Create: `Sources/Canopy/DaemonRegistration.swift`
- Modify: `project.yml`（plist を `Contents/Library/LaunchAgents` にコピーする build phase）
- Modify: `Sources/Canopy/CanopyApp.swift`（`applicationDidFinishLaunching` から呼ぶ）

**Interfaces:**
- Produces: `DaemonRegistration.plistName(bundleId: String) -> String`、`DaemonRegistration.ensureRegistered()`

- [ ] **Step 1: plist を 2 つ書く**

`Resources/LaunchAgents/sh.saqoo.Canopy.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>sh.saqoo.Canopy.daemon</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/Canopy</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/Canopy</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
```

`Resources/LaunchAgents/sh.saqoo.Canopy.debug.daemon.plist` は `Label` を `sh.saqoo.Canopy.debug.daemon` にしただけの同じ内容。

`LimitLoadToSessionType = Aqua` は spec の「LaunchAgent であって LaunchDaemon ではない」の理由（login keychain）をそのまま表したもの。

- [ ] **Step 2: `project.yml` にコピー phase を足す**

`targets.Canopy` に `postBuildScripts` ではなく `copyFiles` を使う。`sources:` の下に追加:

```yaml
      - path: Resources/LaunchAgents
        type: folder
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchAgents
```

`type: folder` はフォルダごとコピーして `Contents/Library/LaunchAgents/LaunchAgents/…` になる可能性がある。Step 4 で実物を確かめ、1 段深ければ `type: folder` を外して 2 ファイルを個別に列挙する:

```yaml
      - path: Resources/LaunchAgents/sh.saqoo.Canopy.daemon.plist
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchAgents
      - path: Resources/LaunchAgents/sh.saqoo.Canopy.debug.daemon.plist
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LaunchAgents
```

- [ ] **Step 3: 登録コードを書く**

`Sources/Canopy/DaemonRegistration.swift`:

```swift
import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonRegistration")

/// Registers `Canopy --daemon` as this user's LaunchAgent. Keyed by bundle
/// id so a Debug build registers its own agent and never replaces Release's.
enum DaemonRegistration {
    static func plistName(bundleId: String) -> String { "\(bundleId).daemon.plist" }

    @MainActor
    static func ensureRegistered() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { return }
        #endif
        let name = plistName(bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        let service = SMAppService.agent(plistName: name)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            logger.notice("daemon agent needs approval in System Settings › Login Items")
            return
        default:
            do {
                try service.register()
                logger.notice("daemon agent registered (\(name, privacy: .public))")
            } catch {
                logger.error("daemon agent register failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
```

`AppDelegate.applicationDidFinishLaunching` の `KeepAliveCoordinator.shared.start()` の直後に:

```swift
        DaemonRegistration.ensureRegistered()
```

（`applicationDidFinishLaunching` は probe の exit より後なので、関数内の probe guard は二重だが、登録は外部に残る副作用なので明示的に置いておく。）

- [ ] **Step 4: probe で plist 名を固定し、バンドルの中身を確かめる**

`_SidebarLogicProbe.swift` に:

```swift
            record("daemon agent: Debug and Release register different plists",
                   DaemonRegistration.plistName(bundleId: "sh.saqoo.Canopy") == "sh.saqoo.Canopy.daemon.plist"
                       && DaemonRegistration.plistName(bundleId: "sh.saqoo.Canopy.debug") == "sh.saqoo.Canopy.debug.daemon.plist")
            record("daemon agent: this build's plist is in the bundle",
                   FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                       .appendingPathComponent("Contents/Library/LaunchAgents")
                       .appendingPathComponent(DaemonRegistration.plistName(bundleId: Bundle.main.bundleIdentifier ?? "")).path))
```

Run:
```bash
xcodegen generate && ./scripts/build_debug_stable.sh
ls build/Build/Products/Debug/Canopy.app/Contents/Library/LaunchAgents/
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | grep -E "daemon agent: |--- "
```
Expected: `ls` が 2 つの plist を直下に出す。`daemon agent:` 2 件 PASS。CI の floor を上げる。

- [ ] **Step 5: 実機で登録を確かめる**

```bash
CANOPY_REGISTER_DAEMON=1 build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy &
sleep 5
launchctl print gui/$(id -u)/sh.saqoo.Canopy.debug.daemon | head -20
```
Expected: `state = running` と `program = …/Canopy`、引数に `--daemon`。Canopy（GUI）を終了しても daemon の pid が残る（`launchctl print` で確かめる）。

後片付け（Debug の agent を残さない）: `build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --unregister-daemon`。`launchctl bootout` はログイン項目の登録を残すので使わない。

- [ ] **Step 6: Commit（許可があれば）**

```bash
git add Resources/LaunchAgents project.yml Sources/Canopy/DaemonRegistration.swift Sources/Canopy/CanopyApp.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Register the daemon as a LaunchAgent"
```

---

### Task 9: studio で受け入れ確認

Plan A の範囲での受け入れ。app 側の client（Plan B）がまだ無いので、nc と TCP で確かめる。

- [ ] **Step 1: studio に Debug ビルドを置く**

studio 上でこのブランチをビルドするか、ビルド済みの `Canopy.app` をコピーして 1 回起動し、LaunchAgent を登録させる。

- [ ] **Step 2: この Mac から TCP で control を叩く**

token は studio の Settings › Mobile の接続文字列から取る（**transcript に表示しない**。変数に入れて使う）。

```bash
STUDIO_IP=<studio の Tailscale IPv4>
{ printf '{"type":"hello","protocolVersion":1,"token":"%s"}\n' "$TOKEN"
  printf '%s\n' '{"type":"request","id":"1","verb":"browse_dir","params":{"path":"/Users/hiko"}}' \
                '{"type":"request","id":"2","verb":"list_sessions","params":{"scope":"recent","limit":5}}'
  sleep 4; } | nc "$STUDIO_IP" 8768  # Debug は daemonPort+1。studio の Mirror が On であること | cut -c1-200
```

Expected: `hello_ok`、id 1 と 2 の `response`。wrong token では `hello_error` で切られる（1 回確かめる）。

- [ ] **Step 3: 永続性を確かめる**

studio で open_session した session が、studio の GUI Canopy を終了しても `launchctl print` の daemon と `list_sessions {scope: "open"}` に残ることを確かめる。

- [ ] **Step 4: reaper を短縮して確かめる**

`DaemonReaper` の limit を一時的に 60 秒にしたビルドで、attach していない session が 2 分以内に `list_sessions {scope:"open"}` から消えることを確かめる。確かめたら既定に戻す（`SessionReaper.defaultIdleLimit`）。

---

## Plan A の後

- **Plan B**：Canopy.app を client にする。サイドバーと launcher を control 接続の上に組み直し、local の pane も `MirrorPaneView` 経由にする。GUI の `MirrorServer` を消して `daemonPort` を `mirrorPort` にまとめる。keep-alive の対象を「attach している client がいる session」に変える。`.requiresApproval` の UI。control verb の `rename_session` / `switch_account` / `restart_session`（client の menu が呼ぶので、呼び手と同じ計画に入れる）。worktree の branch 名を最初の prompt から付ける処理（`WorktreeBranchNamer`、daemon 側で実行）
- **Plan C**：Canopy-Mobile。マシン選択、recents / フォルダ / `browse_dir`、`open_session`
- **Plan D**：SSH remote、in-process session 経路、`.dormant`、#266 の `MirrorRecents` 経路の削除
