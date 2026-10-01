# Canopy Server Plan B2 — local session を daemon に載せ替える

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** この Mac の session（`.local` origin）を GUI の中ではなく local の daemon で動かし、pane はそこに attach する。GUI を閉じても session は残り、開き直すと同じ配置で戻る。

**Architecture:** `SessionStore` の開く経路（新規、resume、Save-and-Quit の復元、teleport）はそのまま残す。変えるのは session を**載せる**ところだけ。`.local` の session が pane に載るとき、`SessionContainer` は shim を作らず、`MirrorPaneView` で daemon の Unix socket に attach する。attach の `open` 要求に、session の設定（model、effort、permission mode、最初の prompt と画像、確定したタイトル、provider、アカウント）を全部載せる。Open 一覧は daemon の `session_state` と同期する（`ControlClient` + `DaemonSessionSync`）。

**Tech Stack:** Swift 6 / macOS 15、Network.framework、SwiftUI、AppKit。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)。B1 は PR #268。B2 はその上の stacked PR（base: `canopy-server-b1`）。

## Global Constraints

- ブランチ `canopy-server-b2`、PR の base は `canopy-server-b1`、draft
- 対象は `.local` origin だけ。`.remote`（SSH）と `.mirror`（他の Mac）は今のまま。SSH remote は Plan D で消える
- **Cmd+W と pane の close X は detach。** session は daemon で動き続け、Open 一覧に pane なしの行として残る。止めるのはサイドバーの「Stop session」だけ
- local の session が pane にあるだけなら、終了時の確認ダイアログは出さず、pane 配置を毎回保存する
- GUI は `.local` の session に `ShimProcess` を作らない。shim に頼る機能（keep-alive、recap、通知、`ContentViewer`、ファイルを開く、phone からの返信、roster）は B2 の間は local の session では動かない。B3 と B4 で戻す。stack は全部そろってからマージする
- daemon が動いていなければ GUI が起動する。Release は `DaemonRegistration`、Debug は `Canopy --daemon` を別プロセスで起動する
- probe の assertion を足したら `.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS` を上げる
- 実機確認で GUI を操作するときは、Debug ビルドだけを使い、window 単位のスクリーンショットだけを撮る（memory の「Screenshots: window-scoped」）。Release の Canopy には触らない
- ファイルを戻すときは `cp` のバックアップから（`git checkout --` は使わない）

## Review Focus

1. **daemon がまだ起動していないうちに pane が attach しようとする。** 起動直後、socket が現れるまでの数秒で、attach が `dropped` になってはいけない。bridge は socket が現れるまで待つ（Task 3、Task 5）
2. **placeholder の resumeId。** GUI が作った新規 session は、CLI が id を差し替えるまで placeholder のまま。差し替えは `session_state`（同じ key）から GUI に届き、Save-and-Quit はその新しい id を保存する（Task 6 に test）
3. **GUI が知らない session。** phone や他の client が daemon で開いた session は、pane なしの行として Open 一覧に出る。daemon が止めた session は一覧から消える。ただし、attach を待っている最中の行（key がまだ無い）は消さない（Task 6 に test）
4. **Cmd+W のあと。** pane は消えるが、行は Open 一覧に残り、もう一度クリックすると同じ session に attach し直す（Task 7）
5. **終了と再起動。** GUI を終了しても session は daemon に残る。再起動すると保存した pane 配置で attach し直し、transcript が描かれる（Task 10）

---

### Task 1: 新規 session の設定を attach の `open` 要求に載せる（wire）

**Files:**
- Modify: `Sources/Canopy/MirrorRecents.swift`（`MirrorOpenRequest`）
- Modify: `Sources/Canopy/LaunchPrompt.swift`（`LaunchImage` に wire 用の factory）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `struct NewSessionOptions: Equatable`（`model: String?`、`effort: String?`、`permissionMode: PermissionMode?`、`promptText: String?`、`promptImages: [WireImage]`、`settledTitle: String?`、`providerId: String?`、`accountId: String?`）と `WireImage: Equatable`（`mediaType: String`、`base64: String`）
  - `MirrorOpenRequest.new(cwd: String, options: NewSessionOptions)`（今の `.new(cwd:)` を置き換える。呼び出し元は `options: .init()` を渡す）
  - `NewSessionOptions.wire: [String: Any]`、`init(wire: [String: Any]?)`（欠けたキーは nil / 空。未知の permission mode は nil）
  - `LaunchImage.fromWire(_ image: WireImage) -> LaunchImage?`（`acceptedMediaTypes` 以外、base64 として読めないもの、`maxBytes` を超えるものは nil）

- [ ] **Step 1: 失敗する assertion を書く**（`mirror endpoint:` の assertion の直後）

```swift
            // Canopy Server: new-session options ride the attach's `open`.
            do {
                let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
                let options = NewSessionOptions(model: "opus", effort: "high", permissionMode: .plan, promptText: "fix it",
                                                promptImages: [WireImage(mediaType: "image/png", base64: png)],
                                                settledTitle: "Fix it", providerId: "prov", accountId: "acct")
                record("open request: a new session's options round-trip",
                       MirrorOpenRequest(wire: MirrorOpenRequest.new(cwd: "/tmp/p", options: options).wire)
                           == .new(cwd: "/tmp/p", options: options))
                record("open request: a bare new session has empty options",
                       MirrorOpenRequest(wire: ["kind": "new", "cwd": "/tmp/p"]) == .new(cwd: "/tmp/p", options: NewSessionOptions()))
                record("open request: an unknown permission mode is dropped, not guessed",
                       NewSessionOptions(wire: ["permissionMode": "yolo"]).permissionMode == nil)
                record("open request: resume is unchanged",
                       MirrorOpenRequest(wire: MirrorOpenRequest.resume.wire) == .resume)
                record("launch image: an accepted type decodes", LaunchImage.fromWire(WireImage(mediaType: "image/png", base64: png)) != nil)
                record("launch image: an unaccepted type is refused",
                       LaunchImage.fromWire(WireImage(mediaType: "image/heic", base64: png)) == nil)
                record("launch image: base64 that does not decode is refused",
                       LaunchImage.fromWire(WireImage(mediaType: "image/png", base64: "%%%")) == nil)
            }
```

- [ ] **Step 2: ビルドして失敗を確かめる**。Expected: `cannot find 'NewSessionOptions' in scope`。

- [ ] **Step 3: 実装する**

`MirrorRecents.swift` の `enum MirrorOpenRequest` の直前に:

```swift
/// An image in a new session's first prompt, as the wire carries it.
struct WireImage: Equatable {
    let mediaType: String
    let base64: String
}

/// What a new session is started with. Rides `MirrorOpenRequest.new`, so the
/// pane that opens a session carries everything the launcher chose.
struct NewSessionOptions: Equatable {
    var model: String? = nil
    var effort: String? = nil
    var permissionMode: PermissionMode? = nil
    var promptText: String? = nil
    var promptImages: [WireImage] = []
    var settledTitle: String? = nil
    var providerId: String? = nil
    var accountId: String? = nil

    init(model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, promptText: String? = nil,
         promptImages: [WireImage] = [], settledTitle: String? = nil, providerId: String? = nil, accountId: String? = nil) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.promptText = promptText
        self.promptImages = promptImages
        self.settledTitle = settledTitle
        self.providerId = providerId
        self.accountId = accountId
    }

    init(wire: [String: Any]?) {
        let wire = wire ?? [:]
        func text(_ key: String) -> String? { (wire[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(model: text("model"), effort: text("effort"),
                  permissionMode: text("permissionMode").flatMap(PermissionMode.init(rawValue:)),
                  promptText: text("promptText"),
                  promptImages: (wire["promptImages"] as? [[String: Any]] ?? []).compactMap {
                      guard let type = $0["mediaType"] as? String, let data = $0["base64"] as? String else { return nil }
                      return WireImage(mediaType: type, base64: data)
                  },
                  settledTitle: text("settledTitle"), providerId: text("providerId"), accountId: text("accountId"))
    }

    var wire: [String: Any] {
        var dict: [String: Any] = [:]
        if let model { dict["model"] = model }
        if let effort { dict["effort"] = effort }
        if let permissionMode { dict["permissionMode"] = permissionMode.rawValue }
        if let promptText { dict["promptText"] = promptText }
        if !promptImages.isEmpty { dict["promptImages"] = promptImages.map { ["mediaType": $0.mediaType, "base64": $0.base64] } }
        if let settledTitle { dict["settledTitle"] = settledTitle }
        if let providerId { dict["providerId"] = providerId }
        if let accountId { dict["accountId"] = accountId }
        return dict
    }
}
```

`MirrorOpenRequest` の `.new(cwd:)` を `.new(cwd: String, options: NewSessionOptions)` にする。`wire` は `["kind": "new", "cwd": cwd, "options": options.wire]`、`init?(wire:)` の `"new"` 分岐は `self = .new(cwd: cwd, options: NewSessionOptions(wire: wire?["options"] as? [String: Any]))`。

コンパイラが指す `.new(cwd:)` の呼び出し元（`LauncherView` の他の Mac のフォルダ行、`MirrorServer.startRequestedSession`、probe）を直す。呼び出し元は `options: NewSessionOptions()`、`startRequestedSession` はパターンを `case .new(let cwd, let options)` にする（options を使うのは Task 2）。

`LaunchPrompt.swift` の `LaunchImage` に:

```swift
    /// An image a client sent over the wire. The same limits as a local attach:
    /// an accepted type, readable base64, within `maxBytes`.
    static func fromWire(_ image: WireImage) -> LaunchImage? {
        guard acceptedMediaTypes.contains(image.mediaType),
              let data = Data(base64Encoded: image.base64), !data.isEmpty, data.count <= maxBytes else { return nil }
        return LaunchImage(mediaType: image.mediaType, data: data)
    }

    var wire: WireImage { WireImage(mediaType: mediaType, base64: data.base64EncodedString()) }
```

- [ ] **Step 4: ビルドして probe**。7 件 PASS、failed 0。floor を上げる。

- [ ] **Step 5: Commit**

```bash
git commit -m "Carry new-session options on the attach's open request"
```

---

### Task 2: daemon が options を使い、Recents にない session も resume する

**Files:**
- Modify: `Sources/Canopy/SessionStore.swift`（`HeadlessOptions`、`startHeadlessSession(directory:…)`）
- Modify: `Sources/Canopy/MirrorServer.swift`（`startRequestedSession`）

**Interfaces:**
- Consumes: Task 1 の `NewSessionOptions`、`LaunchImage.fromWire`、`ModelProviderStore.load()`、`ClaudeAccountStore.account(id:)`、`ClaudeSessionHistory.scanForTranscript(sessionId:)`、`ClaudeSessionHistory.cwd(atPath:)`
- Produces:
  - `HeadlessOptions` に `promptImages: [LaunchImage]`、`settledTitle: String?`、`provider: ModelProvider?`、`account: ClaudeAccount?`（provider と account は、nil なら今までどおり daemon の選択と `launchAccountChoice` を使う）
  - `HeadlessOptions(_ options: NewSessionOptions)`（id を実体に解決する。見つからない provider / account は nil として扱い、ログを残す）

- [ ] **Step 1: `HeadlessOptions` を広げる**

```swift
    struct HeadlessOptions {
        var model: String? = nil
        var effort: String? = nil
        var permissionMode: PermissionMode? = nil
        var initialPrompt: String? = nil
        var promptImages: [LaunchImage] = []
        var settledTitle: String? = nil
        var provider: ModelProvider? = nil
        var account: ClaudeAccount? = nil
    }
```

`HeadlessOptions` の extension（同じファイル、struct の直後）:

```swift
extension SessionStore.HeadlessOptions {
    /// Ids from the wire resolved to this Mac's providers and logins. An id this
    /// Mac does not know falls back to its own choice rather than refusing.
    init(_ wire: NewSessionOptions) {
        self.init(model: wire.model, effort: wire.effort, permissionMode: wire.permissionMode,
                  initialPrompt: wire.promptText, promptImages: wire.promptImages.compactMap(LaunchImage.fromWire),
                  settledTitle: wire.settledTitle,
                  provider: wire.providerId.flatMap { id in ModelProviderStore.load().first { $0.id == id } },
                  account: wire.accountId.flatMap(ClaudeAccountStore.account(id:)))
    }
}
```

（`extension` は `SessionStore` の外、ファイルの末尾に置く。`SessionStore` が `@MainActor` でも、この init は値を組み立てるだけ。）

- [ ] **Step 2: `startHeadlessSession(directory:…)` で使う**

provider と account の選び方を置き換える:

```swift
        let provider = options.provider ?? ModelProviderStore.selectedProvider()
        let accountChoice = launchAccountChoice(customApi: provider)
```

`OpenSession(...)` の `claudeAccount:` を `options.account ?? accountChoice.account` にする。prompt の行を置き換える:

```swift
        if options.initialPrompt != nil || !options.promptImages.isEmpty {
            session.pendingInitialPrompt = LaunchPrompt.make(text: options.initialPrompt ?? "", images: options.promptImages)
        }
        session.pendingSettledTitle = options.settledTitle
        if options.account == nil { session.accountAutoSwitch = accountChoice.autoSwitch }
```

`title:` 引数は `title ?? options.settledTitle ?? "Untitled"` にする。

- [ ] **Step 3: `startRequestedSession` で options を渡し、resume を広げる**

`.new` の分岐:

```swift
        case .new(let cwd, let options):
            ...（フォルダの存在チェックはそのまま）
            shim = store.startHeadlessSession(directory: URL(fileURLWithPath: cwd), resumeId: sessionId,
                                              isExistingTranscript: false, title: nil,
                                              options: SessionStore.HeadlessOptions(options))
```

`.resume` の分岐に、Recents で見つからなかったときの fallback を足す（`else if let entry = store.recents…` の後、`else` の前）:

```swift
            } else if let path = ClaudeSessionHistory.scanForTranscript(sessionId: sessionId),
                      let cwd = ClaudeSessionHistory.cwd(atPath: path) {
                // Recents is refreshed asynchronously and may not hold a session
                // that was just created or teleported; the transcript on disk is the authority.
                shim = store.startHeadlessSession(directory: URL(fileURLWithPath: cwd), resumeId: sessionId,
                                                  isExistingTranscript: true, title: nil)
```

- [ ] **Step 4: ビルドして probe**。failed 0。

- [ ] **Step 5: daemon を `nc` で叩く**

```bash
./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --daemon & D=$!
SOCK="$HOME/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock"
DIR=$(mktemp -d); echo "$DIR"
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' '{"type":"request","id":"1","verb":"subscribe"}'; sleep 1
  printf '{"type":"attach","sessionId":"%s","client":"mac","open":{"kind":"new","cwd":"%s","options":{"model":"haiku","permissionMode":"plan","settledTitle":"Options test"}}}\n' "$(uuidgen | tr A-Z a-z)" "$DIR"
  sleep 5; } | nc -U "$SOCK" | grep -o '"title":"[^"]*"\|"model":"[^"]*"\|"permissionMode":"[^"]*"\|"type":"attach_ok"' | sort -u
kill -TERM $D
```

（hello と attach は別々の接続が要るので、実際には attach 用に 2 本目の `nc` を開く。）

Expected: `attach_ok`。その後の `session_state` で `title: "Options test"`、`permissionMode: "plan"`。後片付けで `$DIR` を消す（パスを直接書いて `rm -rf`）。

- [ ] **Step 6: Commit**

---

### Task 3: daemon の起動を GUI が保証する（`DaemonSupervisor`）

**Files:**
- Create: `Sources/Canopy/DaemonSupervisor.swift`
- Modify: `Sources/Canopy/DaemonRegistration.swift`（登録状態を返す関数を足す）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `DaemonRegistration.status() -> SMAppService.Status`
  - `enum DaemonSupervisor.Action: Equatable { case none, register, launch }`
  - `DaemonSupervisor.action(socketLive: Bool, isDebugBuild: Bool, registration: SMAppService.Status) -> Action`
  - `@MainActor DaemonSupervisor.ensureRunning() async -> Bool`（socket が live になれば true。最大 10 秒待つ）

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            record("daemon supervisor: a live socket needs nothing",
                   DaemonSupervisor.action(socketLive: true, isDebugBuild: false, registration: .notRegistered) == .none)
            record("daemon supervisor: Release registers when not registered",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .notRegistered) == .register)
            record("daemon supervisor: Release launches it itself while approval is pending",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .requiresApproval) == .launch)
            record("daemon supervisor: Release launches when registered but not running",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: false, registration: .enabled) == .launch)
            record("daemon supervisor: Debug always launches its own",
                   DaemonSupervisor.action(socketLive: false, isDebugBuild: true, registration: .notRegistered) == .launch)
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 実装する**

`DaemonRegistration` に:

```swift
    static func status() -> SMAppService.Status { service.status }
```

`Sources/Canopy/DaemonSupervisor.swift`:

```swift
import AppKit
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonSupervisor")

/// Makes sure this build's daemon is serving its socket before a pane attaches.
/// Release relies on the LaunchAgent; a Debug build (not registered by default)
/// and a Release whose registration is waiting on approval start one directly.
enum DaemonSupervisor {
    enum Action: Equatable { case none, register, launch }

    static func action(socketLive: Bool, isDebugBuild: Bool, registration: SMAppService.Status) -> Action {
        if socketLive { return .none }
        if isDebugBuild { return .launch }
        return registration == .notRegistered || registration == .notFound ? .register : .launch
    }

    @MainActor
    static func ensureRunning() async -> Bool {
        let path = DaemonPaths.current
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        switch action(socketLive: DaemonPaths.socketIsLive(path: path), isDebugBuild: isDebug,
                      registration: DaemonRegistration.status()) {
        case .none:
            return true
        case .register:
            DaemonRegistration.ensureRegistered()
        case .launch:
            launch()
        }
        for _ in 0..<50 {
            if DaemonPaths.socketIsLive(path: path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        logger.error("daemon socket did not come up within 10 s")
        return false
    }

    /// A separate process, not a child: it must outlive this GUI.
    @MainActor
    private static func launch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--daemon"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { logger.error("daemon launch failed: \(error.localizedDescription, privacy: .public)") }
        }
        logger.notice("launched a daemon for this build")
    }
}
```

`SMAppService.Status` に `.notFound` が無いときは、その比較を消す（SDK の定義を確かめる）。

- [ ] **Step 4: ビルドして probe**。5 件 PASS。floor を上げる。

- [ ] **Step 5: Commit**

---

### Task 4: `ControlClient` — GUI から daemon の control API を使う

**Files:**
- Create: `Sources/Canopy/ControlClient.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `MirrorEndpoint`（B1）、`NDJSONLineBuffer`、`MirrorWire`、`ControlProtocol`
- Produces:
  - `struct ControlClient.Correlator`（`mutating func begin() -> String`（新しい id）、`mutating func finish(_ response: [String: Any]) -> (id: String, result: Result<[String: Any], ControlClient.Failure>)?`）
  - `enum ControlClient.Failure: Error, Equatable { case refused(String), disconnected }`
  - `@MainActor final class ControlClient`
    - `init(endpoint: MirrorEndpoint, token: String?)`
    - `var onSessionState: (([ControlProtocol.SessionRow]) -> Void)?`
    - `var onConnected: (() -> Void)?`（`hello_ok` のたび。再接続も含む）
    - `func start()`（接続し、`hello` → `subscribe`。切れたら 2 秒後に再接続）
    - `func request(_ verb: String, _ params: [String: Any]) async -> Result<[String: Any], Failure>`
    - `func stop()`

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            do {
                var correlator = ControlClient.Correlator()
                let first = correlator.begin()
                let second = correlator.begin()
                record("control client: request ids are unique", first != second)
                let ok = correlator.finish(["type": "response", "id": first, "result": ["ok": true]])
                record("control client: a result resolves its own id",
                       ok?.id == first && (try? ok?.result.get())?["ok"] as? Bool == true)
                record("control client: an error resolves as refused",
                       correlator.finish(["type": "response", "id": second, "error": "nope"])?.result == .failure(.refused("nope")))
                record("control client: an id resolves once",
                       correlator.finish(["type": "response", "id": first, "result": [:]]) == nil)
                record("control client: an unknown id is ignored",
                       correlator.finish(["type": "response", "id": "zzz", "result": [:]]) == nil)
            }
```

`Result<[String: Any], Failure>` は `Equatable` ではないので、`.failure(.refused("nope"))` との比較は、`if case .failure(let f) = …?.result { return f == .refused("nope") }` の形のクロージャで書く（ビルドエラーになったらこの形に直す）。

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 実装する**

`Sources/Canopy/ControlClient.swift`:

```swift
import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ControlClient")

/// The GUI's control connection to a daemon: requests with one response each,
/// and `session_state` pushes after `subscribe`. Reconnects on its own.
@MainActor
final class ControlClient {
    enum Failure: Error, Equatable { case refused(String), disconnected }

    /// Request ids and the one response each may receive.
    struct Correlator {
        private var next = 0
        private var pending: Set<String> = []

        mutating func begin() -> String {
            next += 1
            let id = "c\(next)"
            pending.insert(id)
            return id
        }

        mutating func finish(_ response: [String: Any]) -> (id: String, result: Result<[String: Any], Failure>)? {
            guard let id = response["id"] as? String, pending.remove(id) != nil else { return nil }
            if let error = response["error"] as? String { return (id, .failure(.refused(error))) }
            return (id, .success(response["result"] as? [String: Any] ?? [:]))
        }

        mutating func failAll() -> [String] {
            defer { pending.removeAll() }
            return Array(pending)
        }
    }

    var onSessionState: (([ControlProtocol.SessionRow]) -> Void)?
    var onConnected: (() -> Void)?

    private let endpoint: MirrorEndpoint
    private let token: String?
    private var connection: NWConnection?
    private let buffer = NDJSONLineBuffer(acceptsCompressed: true)
    private var correlator = Correlator()
    private var waiters: [String: CheckedContinuation<Result<[String: Any], Failure>, Never>] = [:]
    private var ready = false
    private var stopped = false

    init(endpoint: MirrorEndpoint, token: String?) {
        self.endpoint = endpoint
        self.token = token
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        failPending()
    }

    func request(_ verb: String, _ params: [String: Any] = [:]) async -> Result<[String: Any], Failure> {
        guard ready else { return .failure(.disconnected) }
        let id = correlator.begin()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            send(["type": "request", "id": id, "verb": verb, "params": params])
        }
    }

    private func connect() {
        guard !stopped else { return }
        let connection = NWConnection(to: endpoint.nwEndpoint, using: endpoint.parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, of: connection) }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            var hello: [String: Any] = ["type": "hello", "protocolVersion": ControlProtocol.version, "client": "mac"]
            if let token { hello["token"] = token }
            send(hello)
        case .failed, .cancelled:
            dropped()
        case .waiting:
            connection.cancel()
        default:
            break
        }
    }

    private func dropped() {
        ready = false
        connection = nil
        failPending()
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
    }

    private func failPending() {
        for id in correlator.failAll() {
            waiters.removeValue(forKey: id)?.resume(returning: .failure(.disconnected))
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data, !data.isEmpty {
                    guard let frames = self.buffer.append(data), let lines = NDJSONLineBuffer.lines(from: frames) else {
                        connection.cancel()
                        return
                    }
                    lines.forEach(self.handleLine)
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch dict["type"] as? String {
        case "hello_ok":
            ready = true
            send(["type": "request", "id": correlator.begin(), "verb": "subscribe"])
            onConnected?()
        case "hello_error":
            logger.error("daemon refused hello: \(dict["message"] as? String ?? "?", privacy: .public)")
            connection?.cancel()
        case "session_state":
            let rows = (dict["sessions"] as? [[String: Any]] ?? []).compactMap(ControlProtocol.SessionRow.init(wire:))
            onSessionState?(rows)
        case "response":
            if let (id, result) = correlator.finish(dict) { waiters.removeValue(forKey: id)?.resume(returning: result) }
        default:
            break
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { error in
            if let error { logger.error("send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }
}
```

`NDJSONLineBuffer` の API（`append(_:)` と `lines(from:)`）は `MirrorServer.swift` の使い方と同じにする。`subscribe` の返事は `waiters` に無い id なので捨てられる（`correlator.finish` は id を返すが `waiters` に無いので何もしない）。

- [ ] **Step 4: ビルドして probe**。5 件 PASS。floor を上げる。

- [ ] **Step 5: Commit**

---

### Task 5: `.local` の session を daemon に載せる（`SessionContainer` と `MirrorPaneView`）

**Files:**
- Modify: `Sources/Canopy/OpenSession.swift`
- Modify: `Sources/Canopy/MirrorPaneView.swift`
- Modify: `Sources/Canopy/SessionContainer.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1 の `NewSessionOptions`、Task 3 の `DaemonSupervisor.ensureRunning()`、B1 の `MirrorEndpoint` / `RemoteMirrorBridge(endpoint:…key:…)`
- Produces:
  - `OpenSession.isDaemonHosted: Bool`（`origin` が `.local`）
  - `OpenSession.daemonKey: String?`（`attach_ok` の `hostSessionId`、または `DaemonSessionSync` が入れる）
  - `OpenSession.daemonOpenRequest: MirrorOpenRequest?`（まだ daemon に無い session を起こす要求。`resumeIdIsExistingTranscript` なら `.resume`、そうでなければ `.new(cwd:options:)`。`daemonKey` があれば nil）

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            do {
                let dir = URL(fileURLWithPath: "/tmp/p")
                let fresh = OpenSession(origin: .local(dir), resumeId: "new-id", title: "T", project: "p",
                                        permissionMode: .plan, model: "opus", effortLevel: "high")
                fresh.pendingInitialPrompt = LaunchPrompt.make(text: "hi", images: [])
                fresh.pendingSettledTitle = "Settled"
                record("daemon open: a new local session asks for .new with what the launcher chose",
                       fresh.daemonOpenRequest == .new(cwd: "/tmp/p", options: NewSessionOptions(
                           model: "opus", effort: "high", permissionMode: .plan, promptText: "hi", settledTitle: "Settled")))
                let resumed = OpenSession(origin: .local(dir), resumeId: "old-id", title: "T", project: "p",
                                          resumeIdIsExistingTranscript: true)
                record("daemon open: an existing transcript asks for .resume", resumed.daemonOpenRequest == .resume)
                resumed.daemonKey = "K"
                record("daemon open: a session the daemon already holds asks for nothing", resumed.daemonOpenRequest == nil)
                record("daemon hosted: local is, remote and mirror are not",
                       fresh.isDaemonHosted
                           && !OpenSession(origin: .remote(host: "h", path: dir), resumeId: "r", title: "", project: "").isDaemonHosted)
            }
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: `OpenSession` に足す**（`mirrorHostSessionId` の近く）

```swift
    /// This Mac's session, run by the local daemon (Canopy Server). The GUI
    /// attaches to it and never holds its shim.
    var isDaemonHosted: Bool {
        if case .local = origin { return true }
        return false
    }

    /// The daemon's `OpenSession.id` for this session, once it has one.
    var daemonKey: String?

    /// What an attach asks the daemon to start when it does not hold this session yet.
    var daemonOpenRequest: MirrorOpenRequest? {
        guard isDaemonHosted, daemonKey == nil else { return nil }
        if resumeIdIsExistingTranscript { return .resume }
        return .new(cwd: origin.workingDirectory.path, options: NewSessionOptions(
            model: model, effort: effortLevel, permissionMode: permissionMode,
            promptText: pendingInitialPrompt.flatMap { $0.text.isEmpty ? nil : $0.text },
            promptImages: pendingInitialPrompt?.images.map(\.wire) ?? [],
            settledTitle: pendingSettledTitle, providerId: customApi?.id, accountId: claudeAccount?.id))
    }
```

`resumeIdIsExistingTranscript`、`pendingInitialPrompt`、`pendingSettledTitle`、`customApi`、`claudeAccount` は `OpenSession` に既にある（`let` / `var` の区別はファイルで確かめる）。

- [ ] **Step 4: `MirrorPaneView` を daemon でも使う**

`webView(coordinator:)` の `guard let target = session.origin.mirrorTarget, let token = …` を、接続先を決める関数に置き換える:

```swift
    /// Where this pane attaches: another Mac over Tailscale, or this Mac's daemon.
    private func attachTarget() -> (endpoint: MirrorEndpoint, token: String, machine: String)? {
        if let target = session.origin.mirrorTarget {
            guard let token = MirrorAccess.peerToken(machineId: target.machineId) else { return nil }
            return (.tcp(host: target.host, port: target.port), token, session.statusBar.mirrorMachine ?? target.machineId)
        }
        guard session.isDaemonHosted else { return nil }
        return (.unix(path: DaemonPaths.current), "", "this Mac")
    }
```

`guard let target = attachTarget() else { …今のエラー処理… }`。bridge の生成:

```swift
        let bridge = RemoteMirrorBridge(endpoint: target.endpoint, sessionId: session.resumeId, key: session.daemonKey,
                                        token: target.token, webView: webView, fetchesImages: true,
                                        open: session.isDaemonHosted ? session.daemonOpenRequest : session.pendingMirrorOpen)
```

`registerHandlers` の `LinkClickHandler(… opensLocalFiles: false)` を `opensLocalFiles: session.isDaemonHosted` にする（同じ Mac のファイルなので開いてよい）。`machineName` は `target.machine`。

`onOutcome` の `.attached` で `if session.isDaemonHosted, let hostId = bridge?.hostSessionId { session.daemonKey = hostId }` も入れる。`.dropped` で daemon のときの文言を「Could not reach this Mac's session service.」にする。

**daemon の起動待ち（Review Focus 1）。** bridge の生成の前に socket を確かめ、無ければ `DaemonSupervisor.ensureRunning()` を待ってから作る。`webView(coordinator:)` は同期関数なので、webview は先に作って返し、bridge の生成と `session.mirrorBridge` への代入を `Task { @MainActor in … }` の中に移す:

```swift
        if session.isDaemonHosted, !DaemonPaths.socketIsLive(path: DaemonPaths.current) {
            Task { @MainActor [weak session] in
                guard let session else { return }
                guard await DaemonSupervisor.ensureRunning() else {
                    onFailure("This Mac's session service is not running.")
                    return
                }
                attachBridge(to: webView, assetHandler: assetHandler, coordinator: coordinator, session: session)
            }
            session.webView = webView
            return webView
        }
        attachBridge(to: webView, assetHandler: assetHandler, coordinator: coordinator, session: session)
```

`attachBridge` は、今の「bridge を作る → handler を登録 → `onStatus` / `onUsage` / `onFileFrame` / `onOutcome` を設定 → `session.mirrorBridge = bridge`」を切り出した private 関数にする。`registerHandlers` は bridge を要求するので、socket 待ちの間は `vscodeHost` 以外の handler だけを先に登録する形にするか、bridge を作ってから一度に登録する（ページの読み込みは bridge が attach してから始まるので、handler の登録が遅れても取りこぼしは無い）。

- [ ] **Step 5: `SessionContainer` の分岐**

`if session.origin.mirrorTarget != nil {` を `if session.origin.mirrorTarget != nil || session.isDaemonHosted {` にする。ConnectionOverlay の title は、daemon のとき「Connection to This Mac's Session Lost」。`SpawningOverlay` の headline は、daemon のとき今の `"Starting \(session.title)…"` のまま。1.2 秒の `.task` の guard を `guard session.origin.mirrorTarget == nil, !session.isDaemonHosted else { return }` にする。

`MirrorPaneView` の `onFailure` の中の `SessionStore.shared?.remoteAttachError = message` は mirror 用の banner。daemon のときは `SessionStore.shared?.noteSessionFailure(...)` の既存の経路（shim crash と同じ）に渡す。`noteSessionFailure` の引数は `SessionStore.swift` で確かめる。

- [ ] **Step 6: ビルドして probe**。4 件 PASS。floor を上げる。

- [ ] **Step 7: Commit**

---

### Task 6: Open 一覧を daemon と同期する（`DaemonSessionSync`）

**Files:**
- Create: `Sources/Canopy/DaemonSessionSync.swift`
- Modify: `Sources/Canopy/SessionStore.swift`（反映用の関数）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Consumes: B1 の `ControlProtocol.SessionRow`、`RosterSnapshot.activity(fromWireState:)`、Task 5 の `daemonKey` / `isDaemonHosted`
- Produces:
  - `struct DaemonSessionSync.Local: Equatable`（`id: OpenSession.ID`、`key: String?`、`resumeId: String`、`isPaned: Bool`、`awaitingAttach: Bool`）
  - `struct DaemonSessionSync.Plan: Equatable`（`updates: [(OpenSession.ID, ControlProtocol.SessionRow)]` は Equatable にしづらいので `[Update]`、`struct Update: Equatable { id; row }`。`adds: [ControlProtocol.SessionRow]`、`removes: [OpenSession.ID]`）
  - `DaemonSessionSync.plan(rows: [ControlProtocol.SessionRow], local: [Local]) -> Plan`
  - `SessionStore.applyDaemonSessions(_ rows: [ControlProtocol.SessionRow])`

**照合の規則**（`plan` がこれを実装する）:
1. 行とローカルの session は、key が一致すれば同じもの。key の無いローカルの session は、`resumeId` が一致すれば同じもの（新規 session の attach 直後、まだ key を知らないとき）
2. 一致した組は `updates`
3. どのローカルにも一致しない行は `adds`
4. どの行にも一致しないローカルは `removes`。**ただし** `awaitingAttach`（key がまだ無く、pane にある）ものは消さない

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            do {
                func row(_ key: String, _ resume: String) -> ControlProtocol.SessionRow {
                    ControlProtocol.SessionRow(key: key, resumeId: resume, title: "t", project: "p", cwd: "/p", state: "idle",
                                               running: true, clients: 0, lastActiveAt: 0, model: "", messageCount: 0,
                                               permissionMode: "", accountId: nil)
                }
                let a = UUID(), b = UUID(), c = UUID()
                let plan = DaemonSessionSync.plan(
                    rows: [row("KA", "ra-new"), row("KB", "rb"), row("KX", "rx")],
                    local: [.init(id: a, key: "KA", resumeId: "ra-placeholder", isPaned: true, awaitingAttach: false),
                            .init(id: b, key: nil, resumeId: "rb", isPaned: true, awaitingAttach: true),
                            .init(id: c, key: "KGONE", resumeId: "rc", isPaned: false, awaitingAttach: false)])
                record("daemon sync: a key match updates even after the resumeId changed",
                       plan.updates.contains { $0.id == a && $0.row.resumeId == "ra-new" })
                record("daemon sync: a keyless local session matches by resumeId",
                       plan.updates.contains { $0.id == b && $0.row.key == "KB" })
                record("daemon sync: a daemon session the GUI does not know is added",
                       plan.adds.map(\.key) == ["KX"])
                record("daemon sync: a session the daemon no longer holds is removed", plan.removes == [c])
                let waiting = DaemonSessionSync.plan(
                    rows: [], local: [.init(id: a, key: nil, resumeId: "r", isPaned: true, awaitingAttach: true)])
                record("daemon sync: a pane still waiting for its attach is not removed", waiting.removes.isEmpty)
            }
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: `plan` を実装する**

```swift
import Foundation

/// Reconciles the GUI's open local sessions with the daemon's `session_state`.
/// Pure: the probe drives it without a daemon.
enum DaemonSessionSync {
    struct Local: Equatable {
        let id: UUID
        let key: String?
        let resumeId: String
        let isPaned: Bool
        /// In a pane and not yet attached: the daemon may not list it yet.
        let awaitingAttach: Bool
    }

    struct Update: Equatable {
        let id: UUID
        let row: ControlProtocol.SessionRow
    }

    struct Plan: Equatable {
        var updates: [Update] = []
        var adds: [ControlProtocol.SessionRow] = []
        var removes: [UUID] = []
    }

    static func plan(rows: [ControlProtocol.SessionRow], local: [Local]) -> Plan {
        var plan = Plan()
        var matched = Set<UUID>()
        for row in rows where row.key != nil {
            let hit = local.first { $0.key != nil && $0.key == row.key }
                ?? local.first { $0.key == nil && $0.resumeId == row.resumeId }
            if let hit, !matched.contains(hit.id) {
                matched.insert(hit.id)
                plan.updates.append(Update(id: hit.id, row: row))
            } else {
                plan.adds.append(row)
            }
        }
        plan.removes = local.filter { !matched.contains($0.id) && !$0.awaitingAttach }.map(\.id)
        return plan
    }
}
```

- [ ] **Step 4: `SessionStore.applyDaemonSessions` を実装する**

```swift
    /// Brings the open local sessions in line with the daemon's list.
    func applyDaemonSessions(_ rows: [ControlProtocol.SessionRow]) {
        let pairs = openSessions.filter(\.isDaemonHosted)
        let paned = Set(panes.compactMap { if case .session(let id) = $0.content { id } else { nil } })
        let plan = DaemonSessionSync.plan(rows: rows, local: pairs.map {
            .init(id: $0.id, key: $0.daemonKey, resumeId: $0.resumeId, isPaned: paned.contains($0.id),
                  awaitingAttach: $0.daemonKey == nil && paned.contains($0.id))
        })
        for update in plan.updates {
            guard let session = openSessions.first(where: { $0.id == update.id }) else { continue }
            let row = update.row
            session.daemonKey = row.key
            if row.resumeId != session.resumeId {
                session.resumeId = row.resumeId
                session.resumeIdIsExistingTranscript = true
            }
            if !row.title.isEmpty, row.title != session.title { session.title = row.title }
            let activity = RosterSnapshot.activity(fromWireState: row.state)
            session.isThinking = activity == .working
            session.isAsking = activity == .asking
            session.isWaiting = activity == .background
            session.statusBar.model = row.model
            session.statusBar.messageCount = row.messageCount
        }
        for row in plan.adds {
            guard let key = row.key else { continue }
            let session = OpenSession(origin: .local(URL(fileURLWithPath: row.cwd)), resumeId: row.resumeId,
                                      title: row.title.isEmpty ? "Untitled" : row.title, project: row.project,
                                      status: .dormant, resumeIdIsExistingTranscript: true)
            session.daemonKey = key
            openSessions.append(session)
        }
        for id in plan.removes {
            // Stopped elsewhere (another client, the reaper): the pane has nothing to show.
            closeSession(id, keepingFailure: false, stopInDaemon: false)
        }
    }
```

`resumeIdIsExistingTranscript` が `let` なら `var` にする（`OpenSession.swift` で確かめる）。`closeSession(_:keepingFailure:stopInDaemon:)` は Task 7 で作る。`.dormant` の行を pane に載せる経路は `startIfDormant` が `.spawning` にするだけなので、そのまま使える（daemon の session は起動済みなので、attach は `daemonKey` で見つける）。

- [ ] **Step 5: ビルドして probe**。5 件 PASS。floor を上げる。

- [ ] **Step 6: Commit**

---

### Task 7: 閉じる・止める・再起動・rename を daemon に回す

**Files:**
- Modify: `Sources/Canopy/SessionStore.swift`（`closeSession`、`restartSession`、`switchAccount`、`commitRename`、新しい `stopSession`、`daemonControl` の参照）
- Modify: `Sources/Canopy/Sidebar.swift`（「Close session」）
- Modify: `Sources/Canopy/PaneHeaderMenu.swift`（あれば同じ項目）

**Interfaces:**
- Consumes: Task 4 の `ControlClient.request`
- Produces:
  - `SessionStore.daemonControl: ControlClient?`（`CanopyApp` が入れる。Task 9）
  - `closeSession(_:keepingFailure:stopInDaemon: Bool = false)`（daemon の session は、`stopInDaemon` が false なら pane を外して bridge を閉じるだけで、行は残す）
  - `stopSession(_ id: OpenSession.ID)`（`stop_session` を送り、行を消す）

- [ ] **Step 1: `closeSession` を detach にする**

`closeSession` の先頭（`guard let idx` の直後）に:

```swift
        if session.isDaemonHosted, !stopInDaemon {
            // Detach: the daemon keeps running it and the row stays in Open.
            session.mirrorBridge?.close()
            session.mirrorBridge = nil
            session.webView = nil
            session.status = .dormant
            removePanesForClosedSession(id)
            reselectAfterPaneRemoval()
            return
        }
```

（`let session = openSessions[idx]` を `guard let idx` の直後に移す。）今の関数の後半にある「pane が空になったときの selection の決め方」を `reselectAfterPaneRemoval()` に切り出して、detach と通常の close の両方から呼ぶ。detach では「閉じた session の次の行を pane に入れる」挙動は、閉じた行が残っているので要らない（次の行の代わりに launcher を出す）。

- [ ] **Step 2: `stopSession`**

```swift
    /// Stops a daemon session for every client, then drops its row.
    func stopSession(_ id: OpenSession.ID) {
        guard let session = openSessions.first(where: { $0.id == id }) else { return }
        if session.isDaemonHosted, let control = daemonControl {
            let params: [String: Any] = session.daemonKey.map { ["key": $0, "sessionId": session.resumeId] }
                ?? ["sessionId": session.resumeId]
            Task { _ = await control.request("stop_session", params) }
        }
        closeSession(id, keepingFailure: false, stopInDaemon: true)
    }
```

- [ ] **Step 3: 再起動・アカウント切り替え・rename**

`restartSession` の先頭に（`guard let session` の直後）:

```swift
        if session.isDaemonHosted, let control = daemonControl, let key = session.daemonKey {
            Task { _ = await control.request("restart_session", ["key": key]) }
        }
```

（後続の bridge の作り直しと remount は今のまま。attach は key で同じ session に繋がる。）

`switchAccount` は、daemon の session なら `restartSession` を呼ぶ代わりに:

```swift
        if session.isDaemonHosted, let control = daemonControl, let key = session.daemonKey {
            Task { _ = await control.request("switch_account", ["key": key, "accountId": account?.id ?? ""]) }
            restartSession(id)   // bridge を作り直して attach し直す。restart_session は送らない
            return
        }
```

（`restartSession` の中の `restart_session` 送信と二重にならないよう、`restartSession` に `notifyDaemon: Bool = true` を足し、ここでは false で呼ぶ。）

`commitRename` の、ライブの session を見つけたあとに:

```swift
        if let session, session.isDaemonHosted, let control = daemonControl, let key = session.daemonKey {
            Task { _ = await control.request("rename_session", ["key": key, "title": trimmed]) }
        }
```

（ローカルの `SessionTitleStore` への保存と `session.title` の更新は今のまま残す。daemon 側も同じ UserDefaults に書くが、どちらも同じ値なので害は無い。）

- [ ] **Step 4: サイドバー**

`Sidebar.swift:497` の `Button("Close session") { store.closeSession(s.id, keepingFailure: false) }` を:

```swift
            if s.isDaemonHosted {
                Button("Stop session") { store.stopSession(s.id) }
            } else {
                Button("Close session") { store.closeSession(s.id, keepingFailure: false) }
            }
```

`PaneHeaderMenu.swift` に同じ「Close session」項目があれば同様にする。

- [ ] **Step 5: ビルドして probe**。failed 0。

- [ ] **Step 6: Commit**

---

### Task 8: 終了時の確認と window を閉じる挙動

**Files:**
- Modify: `Sources/Canopy/CanopyApp.swift`（`applicationShouldTerminate`、`windowCloseOnly`）

- [ ] **Step 1: 終了時**

`applicationShouldTerminate` の `if ShimProcess.hasActiveSession { … }` の後に:

```swift
        else if SessionStore.shared?.panes.contains(where: { pane in
            if case .session(let id) = pane.content { return SessionStore.shared?.openSessions.first { $0.id == id }?.isDaemonHosted == true }
            return false
        }) == true {
            // Daemon sessions outlive this quit; there is nothing to stop and the layout is always worth keeping.
            Self.shouldSaveRestoreSnapshot = true
        }
```

（`if … { } else if … { }` の形にする。長い既存コメントには触らない。）

- [ ] **Step 2: window を閉じる**

`windowCloseOnly` の `ShimProcess.hasActiveSession` はそのまま（in-process の shim は SSH remote だけになる）。daemon の session しか無いときは window が本当に閉じる。これで良い（session は daemon に残る）。変更なし、と ledger に書く。

- [ ] **Step 3: ビルドする**。

- [ ] **Step 4: Commit**

---

### Task 9: 起動時に daemon・`ControlClient`・同期を始める

**Files:**
- Modify: `Sources/Canopy/CanopyApp.swift`（`WindowGroup` の `.task`、AppDelegate）

- [ ] **Step 1: `.task` を足す**（`startMirrorServer` の `.task` の隣）

```swift
            .task { await appDelegate.startDaemonControl(store: sidebarStore) }
```

AppDelegate に:

```swift
    private var daemonControl: ControlClient?

    /// Same probe guard as the other `.task`s: it launches a process and opens a socket.
    @MainActor
    func startDaemonControl(store: SessionStore) async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { return }
        #endif
        guard daemonControl == nil else { return }
        _ = await DaemonSupervisor.ensureRunning()
        let client = ControlClient(endpoint: .unix(path: DaemonPaths.current), token: nil)
        client.onSessionState = { [weak store] rows in store?.applyDaemonSessions(rows) }
        daemonControl = client
        store.daemonControl = client
        client.start()
    }
```

- [ ] **Step 2: ビルドして probe**。failed 0（probe は guard で daemon を起動しない）。

- [ ] **Step 3: Commit**

---

### Task 10: 実機で確かめる（Debug ビルド）

**Files:** なし

Debug ビルドだけを使う。Release の Canopy とその daemon には触らない。GUI の操作は、Saqoosha に頼むか、window 単位のスクリーンショットとログで確かめる。

- [ ] **Step 1: 起動して新規 session**

Debug の GUI を起動し、launcher から一時フォルダで新規 session を開き、短い prompt を送る。確かめること:
- `ps` に `Canopy --daemon`（Debug）がいて、GUI の子プロセスではない（PPID が 1 か launchd）
- GUI の子に `node`（shim）がいない。daemon の子にいる
- pane に transcript と返事が描かれる
- サイドバーの dot が working → idle と変わる

- [ ] **Step 2: Cmd+W（Review Focus 4）**

pane を閉じる。行が Open 一覧に残る。行をクリックすると attach し直し、transcript が戻る。

- [ ] **Step 3: 終了と再起動（Review Focus 5）**

GUI を終了する。確認ダイアログは出ない。`nc -U` の `list_sessions` で session が daemon に残っていることを確かめる。GUI を再起動すると同じ pane 配置で attach し、transcript が描かれる。

- [ ] **Step 4: Stop session**

サイドバーの「Stop session」で止める。行が消え、`list_sessions` からも消える。

- [ ] **Step 5: 後片付け**

Debug の daemon を SIGTERM で止める。一時フォルダを消す（パスを直接書く）。

---

## B2 に入れないもの

- keep-alive、recap、通知、`ContentViewer`、ファイルを開く、URL・Terminal・アラート、エラーバナー → B3
- roster と phone（local の session が phone から見えない状態は B4 で戻る）、利用量 → B4
- 他の Mac から local の session に attach する経路（今は GUI の mirror server。local の session は daemon に移るので見えなくなる）→ B5 で daemon のポートに移す
- `permissionMode` を webview の変更に追従させる（`SessionRow.permissionMode` は起動時の値）→ B3
