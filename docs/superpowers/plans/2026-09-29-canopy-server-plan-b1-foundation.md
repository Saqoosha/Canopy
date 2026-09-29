# Canopy Server Plan B1 — client の土台（id、session 行、verb、Unix socket 接続）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Canopy.app が daemon の client になるために必要な、server 側の API と client 側の接続口をそろえる。UI はまだ変えない。

**Architecture:** daemon 上の session を、CLI が `resumeId` を差し替えても、daemon が動いている間は変わらない **key**（daemon の `OpenSession.id`）で指せるようにする。`session_state` の行を値型 `SessionRow` にして、サイドバーが要る情報（タイトル、状態、model、件数、permission mode、アカウント）を載せる。client の menu が呼ぶ verb（rename / restart / switch_account / list_accounts）を足す。`RemoteMirrorBridge` を Unix socket でも繋げるようにする。

**Tech Stack:** Swift 6 / macOS 15、Network.framework。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)。Plan A は PR #267。B1 はその上の stacked PR（base: `canopy-server-architecture`）。

## Global Constraints

- ブランチ `canopy-server-b1`、PR の base は `canopy-server-architecture`
- UI（サイドバー、pane、launcher）の見た目と挙動は変えない。GUI は今までどおり in-process の shim を使う。B1 の成果物は daemon の API と client 側の部品だけ
- session の key は daemon の `OpenSession.id.uuidString`。daemon の生存中だけ有効（daemon が再起動すると session は全部止まるので、それ以上長く持つ必要はない）。永続化（Save-and-Quit）には従来どおり `resumeId` を使う
- verb は key を優先し、無ければ `sessionId`（= `resumeId`）で探す
- ローカルの Unix socket 接続には token を送らない（Plan A で `trustsPeer`）
- probe の assertion を足したら、`.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS` を probe が出した passed の数に上げる
- **コミットは Saqoosha の指示があったときだけ**
- ファイルを戻すときは `git checkout --` を使わず、`cp` のバックアップから戻す

## ビルドとテストのコマンド

```bash
cd /Users/hiko/.claude/worktrees/Canopy/canopy-server-architecture
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

daemon を手で動かすときは次の形。終わったら必ず止める。

```bash
./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --daemon &
SOCK="$HOME/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock"
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' '<request lines>'; sleep 5; } | nc -U "$SOCK"
kill -TERM <pid>
```

## Review Focus

1. **`resumeId` が途中で CLI の id に差し替わる。** key で指せば、差し替え後も同じ session に届く。`session_state` の行は key が同じまま `resumeId` だけが変わる（Task 6 で手で確かめる）
2. **閉じた session（recents）の行には key が無い。** client は key の有無で「開いている／閉じている」を区別できなければならない（Task 1 に test）
3. **key と `sessionId` の両方が来たら key が勝つ。** 片方だけでも通る。どちらも無ければエラー（Task 2 に test）
4. **daemon 上の restart は、pane が無いので shim を自分で起こし直す必要がある。** `restartSession` だけでは `.dormant` のまま止まる（Task 3 で手で確かめる）
5. **Unix socket の接続では token を要求しない。** TCP では今までどおり要求する（Task 5 に test）

---

### Task 1: `SessionRow` — session 行の値型

**Files:**
- Modify: `Sources/Canopy/ControlProtocol.swift`（末尾に追加）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`（`daemon config:` の assertion 群の直後）
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `ControlProtocol.SessionRow: Equatable`
    - `key: String?`（開いている session だけ。daemon の `OpenSession.id.uuidString`）
    - `resumeId: String`、`title: String`、`project: String`、`cwd: String`
    - `state: String`（`RosterSnapshot.wireState(for:)` の値。閉じた行は `"closed"`）
    - `running: Bool`、`clients: Int`、`lastActiveAt: Double`
    - `model: String`、`messageCount: Int`、`permissionMode: String`、`accountId: String?`
    - `var wire: [String: Any]`、`init?(wire: [String: Any])`

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            // Canopy Server session rows.
            do {
                let open = ControlProtocol.SessionRow(
                    key: "K1", resumeId: "r1", title: "Fix it", project: "Canopy", cwd: "/tmp/p",
                    state: "working", running: true, clients: 2, lastActiveAt: 1_000,
                    model: "opus", messageCount: 12, permissionMode: "plan", accountId: "acct")
                record("session row: an open row round-trips through the wire",
                       ControlProtocol.SessionRow(wire: open.wire) == open)
                let closed = ControlProtocol.SessionRow(
                    key: nil, resumeId: "r2", title: "Old", project: "Canopy", cwd: "/tmp/p",
                    state: "closed", running: false, clients: 0, lastActiveAt: 500,
                    model: "", messageCount: 0, permissionMode: "", accountId: nil)
                record("session row: a closed row carries no key and round-trips",
                       closed.wire["key"] == nil && ControlProtocol.SessionRow(wire: closed.wire) == closed)
                record("session row: a row without resumeId is rejected",
                       ControlProtocol.SessionRow(wire: ["key": "K", "title": "t"]) == nil)
                record("session row: missing optional fields read as empty, not as a rejection",
                       ControlProtocol.SessionRow(wire: ["resumeId": "r3"])
                           == ControlProtocol.SessionRow(key: nil, resumeId: "r3", title: "", project: "", cwd: "",
                                                         state: "closed", running: false, clients: 0, lastActiveAt: 0,
                                                         model: "", messageCount: 0, permissionMode: "", accountId: nil))
            }
```

- [ ] **Step 2: ビルドして失敗を確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: `type 'ControlProtocol' has no member 'SessionRow'`。

- [ ] **Step 3: 実装する**

`ControlProtocol.swift` の `enum ControlProtocol {` の閉じ括弧の直前に:

```swift
    /// One session as `list_sessions` and `session_state` send it. `key` is the
    /// daemon's `OpenSession.id`: it survives the CLI replacing a placeholder
    /// `resumeId`, and exists only while the session is open.
    struct SessionRow: Equatable {
        let key: String?
        let resumeId: String
        let title: String
        let project: String
        let cwd: String
        let state: String
        let running: Bool
        let clients: Int
        let lastActiveAt: Double
        let model: String
        let messageCount: Int
        let permissionMode: String
        let accountId: String?

        var wire: [String: Any] {
            var dict: [String: Any] = [
                "resumeId": resumeId, "title": title, "project": project, "cwd": cwd, "state": state,
                "running": running, "clients": clients, "lastActiveAt": lastActiveAt,
                "model": model, "messageCount": messageCount, "permissionMode": permissionMode,
            ]
            if let key { dict["key"] = key }
            if let accountId { dict["accountId"] = accountId }
            return dict
        }

        init(key: String?, resumeId: String, title: String, project: String, cwd: String, state: String,
             running: Bool, clients: Int, lastActiveAt: Double, model: String, messageCount: Int,
             permissionMode: String, accountId: String?) {
            self.key = key
            self.resumeId = resumeId
            self.title = title
            self.project = project
            self.cwd = cwd
            self.state = state
            self.running = running
            self.clients = clients
            self.lastActiveAt = lastActiveAt
            self.model = model
            self.messageCount = messageCount
            self.permissionMode = permissionMode
            self.accountId = accountId
        }

        init?(wire: [String: Any]) {
            guard let resumeId = wire["resumeId"] as? String, !resumeId.isEmpty else { return nil }
            self.init(key: wire["key"] as? String, resumeId: resumeId,
                      title: wire["title"] as? String ?? "", project: wire["project"] as? String ?? "",
                      cwd: wire["cwd"] as? String ?? "", state: wire["state"] as? String ?? "closed",
                      running: wire["running"] as? Bool ?? false, clients: wire["clients"] as? Int ?? 0,
                      lastActiveAt: wire["lastActiveAt"] as? Double ?? 0, model: wire["model"] as? String ?? "",
                      messageCount: wire["messageCount"] as? Int ?? 0,
                      permissionMode: wire["permissionMode"] as? String ?? "",
                      accountId: wire["accountId"] as? String)
        }
    }
```

`lastActiveAt` は JSON で整数に丸まって来ることがある（`1000` は `Int` として bridge される）。`as? Double` は NSNumber からなら整数でも取れるので問題ない。Step 4 の round-trip はメモリ上の dict で確かめるだけなので、Task 6 の nc で実際の JSON も確かめる。

- [ ] **Step 4: ビルドして probe**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | grep -E "session row:|--- "`
Expected: `session row:` 4 件 PASS、failed 0。floor を上げる。

- [ ] **Step 5: Commit（指示があれば）**

```bash
git add Sources/Canopy/ControlProtocol.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Add the control API's session row type"
```

---

### Task 2: session の指し方（key か resumeId）

**Files:**
- Modify: `Sources/Canopy/ControlProtocol.swift`
- Modify: `Sources/Canopy/SessionStore.swift`（`startHeadlessSession(resumeId:)` の直後に 1 関数）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `ControlProtocol.SessionRef: Equatable`（`.key(String)` / `.resumeId(String)`）
  - `ControlProtocol.sessionRef(_ params: [String: Any]) -> SessionRef?`（`key` を優先、次に `sessionId`。空文字は無いものとして扱う）
  - `SessionStore.openSession(for ref: ControlProtocol.SessionRef) -> OpenSession?`

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            record("session ref: key wins over sessionId",
                   ControlProtocol.sessionRef(["key": "K", "sessionId": "r"]) == .key("K"))
            record("session ref: sessionId alone is a resumeId",
                   ControlProtocol.sessionRef(["sessionId": "r"]) == .resumeId("r"))
            record("session ref: an empty key falls back to sessionId",
                   ControlProtocol.sessionRef(["key": "", "sessionId": "r"]) == .resumeId("r"))
            record("session ref: neither is nil",
                   ControlProtocol.sessionRef([:]) == nil && ControlProtocol.sessionRef(["key": "", "sessionId": ""]) == nil)
```

- [ ] **Step 2: ビルドして失敗を確かめる**

Expected: `type 'ControlProtocol' has no member 'sessionRef'`。

- [ ] **Step 3: 実装する**

`ControlProtocol.swift`（`SessionRow` の直前）:

```swift
    enum SessionRef: Equatable {
        case key(String)
        case resumeId(String)
    }

    /// `key` (the daemon's `OpenSession.id`) outranks `sessionId` (a `resumeId`),
    /// which the CLI may already have replaced.
    static func sessionRef(_ params: [String: Any]) -> SessionRef? {
        if let key = params["key"] as? String, !key.isEmpty { return .key(key) }
        if let id = params["sessionId"] as? String, !id.isEmpty { return .resumeId(id) }
        return nil
    }
```

`SessionStore.swift`（`startHeadlessSession(resumeId:)` の直後、空行を 1 行はさんで）:

```swift

    /// The open session a control request names.
    func openSession(for ref: ControlProtocol.SessionRef) -> OpenSession? {
        switch ref {
        case .key(let key): return openSessions.first { $0.id.uuidString == key }
        case .resumeId(let id): return openSessions.first { $0.resumeId == id }
        }
    }
```

- [ ] **Step 4: ビルドして probe**。`session ref:` 4 件 PASS。floor を上げる。

- [ ] **Step 5: Commit（指示があれば）**

---

### Task 3: `ControlSession` — 行の送り方と新しい verb

**Files:**
- Modify: `Sources/Canopy/ControlSession.swift`

**Interfaces:**
- Consumes: Task 1 の `SessionRow`、Task 2 の `sessionRef` / `openSession(for:)`、`SessionStore.commitRename(_:to:)`、`SessionStore.RenameTarget`、`SessionStore.restartSession(_:)`、`SessionStore.switchAccount(_:to:)`、`SessionStore.startHeadlessSession(resumeId:)`、`ClaudeAccountStore.load()` / `.account(id:)` / `.defaultAccountId()`、`OpenSession.claudeAccount`、`StatusBarData.model` / `.messageCount`
- Produces（wire）:
  - `list_sessions` と `session_state` の行は `SessionRow.wire`
  - `open_session` の結果に `key` を足す：`{sessionId, key, cwd}`
  - `stop_session {key | sessionId}`
  - `rename_session {key | sessionId, title}` → `{ok: true}`
  - `restart_session {key | sessionId}` → `{ok: true}`
  - `switch_account {key | sessionId, accountId: String | null}` → `{ok: true}`（null は既定のログイン）
  - `list_accounts` → `{accounts: [{id, name}], defaultId}`

- [ ] **Step 1: 行を `SessionRow` にする**

`ControlSession.openRows()` を置き換える:

```swift
    private func openRows() -> [ControlProtocol.SessionRow] {
        store.openSessions.map { session in
            let activity = SessionActivity.of(session, isUnread: store.unreadSessionIds.contains(session.id))
            return ControlProtocol.SessionRow(
                key: session.id.uuidString, resumeId: session.resumeId, title: session.title,
                project: session.project, cwd: session.origin.workingDirectory.path,
                state: RosterSnapshot.wireState(for: activity), running: session.shim?.isLive == true,
                clients: session.shim?.mirrorCount ?? 0, lastActiveAt: session.lastActiveAt.timeIntervalSince1970,
                model: session.statusBar.model, messageCount: session.statusBar.messageCount,
                permissionMode: session.permissionMode.rawValue, accountId: session.claudeAccount?.id)
        }
    }
```

`statusBar.model` と `statusBar.messageCount` の型は `StatusBarData.swift` で確かめる。`String` / `Int` でなければ、ここで変換する。

`listSessions` の `"open"` 分岐を `reply(request, ["sessions": openRows().prefix(limit).map(\.wire)])` に、`"recent"` 分岐の `.map { … }` を次に置き換える:

```swift
                    .map { ControlProtocol.SessionRow(
                        key: nil, resumeId: $0.id, title: $0.title, project: $0.projectName,
                        cwd: $0.projectDirectory.path, state: "closed", running: false, clients: 0,
                        lastActiveAt: $0.timestamp.timeIntervalSince1970, model: "", messageCount: 0,
                        permissionMode: "", accountId: nil).wire }
```

push の判定を行の等値比較にする。`lastPushed` を `[ControlProtocol.SessionRow]?` にして、`pushIfChanged` を置き換える:

```swift
    private func pushIfChanged(_ rows: [ControlProtocol.SessionRow]) {
        guard !stopped, rows != lastPushed else { return }
        lastPushed = rows
        send(["type": "session_state", "sessions": rows.map(\.wire)])
    }
```

`trackOpenSessions` と `subscribe` のタイマーはそのまま（型だけ合う）。型のドキュメントコメントの「when a row's id, title, state, clients or running changes」は「when a row changes」に直す。

- [ ] **Step 2: `open_session` の結果に key、`stop_session` を ref で**

`openSession` の最後:

```swift
        guard let shim = store.startHeadlessSession(directory: directory, resumeId: sessionId, isExistingTranscript: false,
                                                    title: nil, options: options),
              let session = shim.boundSession else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["sessionId": sessionId, "key": session.id.uuidString, "cwd": directory.path])
```

`stopSession` を置き換える:

```swift
    private func stopSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        store.closeSession(session.id, keepingFailure: false)
        reply(request, ["ok": true])
    }

    /// The open session a request names, or nil after answering the request with the reason.
    private func requestedSession(_ request: ControlProtocol.Request) -> OpenSession? {
        guard let ref = ControlProtocol.sessionRef(request.params) else {
            fail(request, "key or sessionId is required")
            return nil
        }
        guard let session = store.openSession(for: ref) else {
            fail(request, "no such session")
            return nil
        }
        return session
    }
```

- [ ] **Step 3: 新しい verb**

`handle` の switch に足す:

```swift
        case "rename_session": renameSession(request)
        case "restart_session": restartSession(request)
        case "switch_account": switchAccount(request)
        case "list_accounts": listAccounts(request)
```

実装（`stopSession` の後）:

```swift
    private func renameSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        guard let title = request.params["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(request, "title is required")
            return
        }
        store.commitRename(SessionStore.RenameTarget(sessionId: session.resumeId, openSessionId: session.id,
                                                     currentTitle: session.title), to: title)
        reply(request, ["ok": true])
    }

    /// The daemon has no pane to remount, so after `restartSession` parks the
    /// row it starts the shim again itself.
    private func restartSession(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        store.restartSession(session.id)
        guard store.startHeadlessSession(resumeId: session.resumeId) != nil else {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["ok": true])
    }

    private func switchAccount(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        let accountId = request.params["accountId"] as? String
        let account = accountId.flatMap { ClaudeAccountStore.account(id: $0) }
        if accountId != nil, account == nil {
            fail(request, "no such account")
            return
        }
        store.switchAccount(session.id, to: account)
        if session.shim == nil, store.startHeadlessSession(resumeId: session.resumeId) == nil {
            fail(request, MirrorOpenRequest.startFailed)
            return
        }
        reply(request, ["ok": true])
    }

    private func listAccounts(_ request: ControlProtocol.Request) {
        let accounts = ClaudeAccountStore.load().map { ["id": $0.id, "name": $0.name] }
        reply(request, ["accounts": accounts, "defaultId": ClaudeAccountStore.defaultAccountId()])
    }
```

`switchAccount` は、アカウントが同じなら `SessionStore.switchAccount` が何もしない（shim が生きたまま）。違えば `restartSession` が shim を止めるので、`session.shim == nil` を見て起こし直す。`ClaudeAccountStore.defaultAccountId()` の戻り値の型（`String`）は `ClaudeAccount.swift:126` で確かめる。

- [ ] **Step 4: ビルドする**

Run: `./scripts/build_debug_stable.sh && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1`
Expected: ビルド成功、failed 0。

- [ ] **Step 5: Commit（指示があれば）**

---

### Task 4: key で attach する

**Files:**
- Modify: `Sources/Canopy/MirrorServer.swift`（`handleAttach`）

**Interfaces:**
- Consumes: Task 2 の `sessionRef` / `openSession(for:)`
- Produces（wire）: `attach` の最初の行に任意の `key`。あれば key で探し、無ければ今までどおり `sessionId`。`attach_ok` の `sessionId` には、見つかった session の **現在の** `resumeId` を入れる

- [ ] **Step 1: 探し方を置き換える**

`handleAttach` の

```swift
        var existing = store.openSessions.first(where: { $0.resumeId == sessionId })?.shim.flatMap { $0.isLive ? $0 : nil }
```

を次に置き換える:

```swift
        let named = ControlProtocol.sessionRef(dict).flatMap { store.openSession(for: $0) }
        var existing = named?.shim.flatMap { $0.isLive ? $0 : nil }
```

`guard let type = …, let sessionId = dict["sessionId"] as? String` はそのまま残す（`sessionId` は `open` 付きの attach で新しい session を作るときに要る）。`attach_ok` の `"sessionId": sessionId` を `"sessionId": existing?.boundSession?.resumeId ?? sessionId` にする。attach 後の `attachedSessionId = sessionId` も同じ値にそろえる（画像の保存キーがこれを使う）。

`sessionRef` は `sessionId` より `key` を優先するので、key を送らない既存の client（phone、他の Mac の `.mirror` pane）は今までどおり `sessionId` で探される。

- [ ] **Step 2: ビルドする**。failed 0。

- [ ] **Step 3: Commit（指示があれば）**

---

### Task 5: `RemoteMirrorBridge` を Unix socket でも繋ぐ

**Files:**
- Create: `Sources/Canopy/MirrorEndpoint.swift`
- Modify: `Sources/Canopy/MirrorClient.swift`（`RemoteMirrorBridge.init`）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `enum MirrorEndpoint: Equatable { case tcp(host: String, port: UInt16); case unix(path: String) }`
  - `MirrorEndpoint.needsToken: Bool`（`.tcp` だけ true）
  - `MirrorEndpoint.parameters: NWParameters`（`.tcp` は今の keepalive 付き、`.unix` は素の `.tcp`）
  - `MirrorEndpoint.nwEndpoint: NWEndpoint`
  - `RemoteMirrorBridge.init(endpoint:sessionId:key:token:webView:fetchesImages:open:)`。今の `init(host:port:…)` は `.tcp` でこれを呼ぶ便宜 init として残す

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            record("mirror endpoint: only TCP needs the password",
                   MirrorEndpoint.tcp(host: "100.1.2.3", port: 8767).needsToken
                       && !MirrorEndpoint.unix(path: "/tmp/x.sock").needsToken)
            record("mirror endpoint: a unix path becomes a unix NWEndpoint", {
                if case .unix(let path) = MirrorEndpoint.unix(path: "/tmp/x.sock").nwEndpoint { return path == "/tmp/x.sock" }
                return false
            }())
            record("mirror endpoint: TCP keeps the 15/15/3 keepalive", {
                guard let tcp = MirrorEndpoint.tcp(host: "100.1.2.3", port: 8767).parameters
                        .defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options else { return false }
                return tcp.enableKeepalive && tcp.keepaliveIdle == 15 && tcp.keepaliveInterval == 15 && tcp.keepaliveCount == 3
            }())
```

- [ ] **Step 2: ビルドして失敗を確かめる**。Expected: `cannot find 'MirrorEndpoint' in scope`。

- [ ] **Step 3: 実装する**

`Sources/Canopy/MirrorEndpoint.swift`:

```swift
import Network

/// Where a `RemoteMirrorBridge` connects: another Mac's server over Tailscale,
/// or this Mac's daemon over its Unix socket.
enum MirrorEndpoint: Equatable {
    case tcp(host: String, port: UInt16)
    case unix(path: String)

    /// The local socket is trusted by file permission (see `MirrorServer.startLocal`).
    var needsToken: Bool {
        if case .tcp = self { return true }
        return false
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .tcp(let host, let port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        case .unix(let path): .unix(path: path)
        }
    }

    /// TCP keeps the keepalive a dead peer needs to surface as a drop (~45 s,
    /// measured against a SIGKILLed server over Tailscale). A Unix socket's
    /// peer dying closes it, so it needs none.
    var parameters: NWParameters {
        switch self {
        case .tcp:
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 3
            return NWParameters(tls: nil, tcp: tcp)
        case .unix:
            return .tcp
        }
    }
}
```

`RemoteMirrorBridge` の `init(host:port:…)` を `init(endpoint:…)` に変え、接続の生成を置き換える:

```swift
    init(endpoint: MirrorEndpoint, sessionId: String, key: String? = nil, token: String, webView: WKWebView,
         fetchesImages: Bool = false, open: MirrorOpenRequest? = nil) {
        self.fetchesImages = fetchesImages
        self.openRequest = open
        self.token = token
        self.sessionId = sessionId
        self.key = key
        self.webView = webView
        self.connection = NWConnection(to: endpoint.nwEndpoint, using: endpoint.parameters)
        // … 以降の super.init() / stateUpdateHandler / start / 15 秒タイムアウトは今のまま
    }

    convenience init(host: String, port: UInt16, sessionId: String, token: String, webView: WKWebView,
                     fetchesImages: Bool = false, open: MirrorOpenRequest? = nil) {
        self.init(endpoint: .tcp(host: host, port: port), sessionId: sessionId, token: token, webView: webView,
                  fetchesImages: fetchesImages, open: open)
    }
```

keepalive を説明している既存コメント（「Keepalive, because a server that dies…」）は `MirrorEndpoint.parameters` に移したので、init からは消す。`private let key: String?` を `sessionId` の隣に足し、`onReady` で送っている attach の dict に `if let key { attach["key"] = key }` を足す（`onReady` の中で attach の dict を組み立てている箇所を探して、そこに入れる）。

`RemoteMirrorBridge` は `NSObject` の subclass なので、`convenience init` から designated init を呼ぶ形でよい。

- [ ] **Step 4: ビルドして probe**。`mirror endpoint:` 3 件 PASS、failed 0。floor を上げる。既存の呼び出し元（`MirrorPaneView.swift:187`、`MirrorAttachWindow.swift:71`）は便宜 init のままでビルドが通ること。

- [ ] **Step 5: Commit（指示があれば）**

---

### Task 6: daemon を手で叩いて確かめる

**Files:** なし（確認だけ）

- [ ] **Step 1: daemon を起動し、session を 1 つ開く**

```bash
./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy --daemon &
D=$!
SOCK="$HOME/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.debug.sock"
DIR=$(mktemp -d)
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' '{"type":"request","id":"1","verb":"subscribe"}' \
    "{\"type\":\"request\",\"id\":\"2\",\"verb\":\"open_session\",\"params\":{\"cwd\":\"$DIR\"}}" \
    '{"type":"request","id":"3","verb":"list_accounts"}'; sleep 6; } | nc -U "$SOCK"
```

Expected: id 2 の結果に `key` がある。`session_state` の行に `key`、`resumeId`、`model`、`messageCount`、`permissionMode` がある。id 3 が `accounts` と `defaultId` を返す。

- [ ] **Step 2: key で操作する**（`<KEY>` は Step 1 の key）

```bash
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' '{"type":"request","id":"1","verb":"subscribe"}' \
    '{"type":"request","id":"2","verb":"rename_session","params":{"key":"<KEY>","title":"Renamed by key"}}' \
    '{"type":"request","id":"3","verb":"restart_session","params":{"key":"<KEY>"}}' \
    '{"type":"request","id":"4","verb":"rename_session","params":{"key":"nope","title":"x"}}' \
    '{"type":"request","id":"5","verb":"stop_session","params":{}}'; sleep 8; } | nc -U "$SOCK"
```

Expected:
- `session_state` のタイトルが `Renamed by key` に変わる
- restart の後も `running: true` の行が同じ key で残る（Review Focus 4）
- id 4 は `no such session`、id 5 は `key or sessionId is required`

- [ ] **Step 3: key で attach し、止めて後片付け**

```bash
{ printf '%s\n' '{"type":"attach","sessionId":"ignored","key":"<KEY>","client":"mac"}'; sleep 3; } | nc -U "$SOCK" | head -c 200
{ printf '%s\n' '{"type":"hello","protocolVersion":1}' '{"type":"request","id":"1","verb":"stop_session","params":{"key":"<KEY>"}}'; sleep 2; } | nc -U "$SOCK"
kill -TERM $D
rm -rf "$DIR"
```

Expected: attach は `attach_ok`（`sessionId` が "ignored" ではなく、その session の実際の resumeId になっている）。stop は `ok`。daemon は SIGTERM で終わり、socket ファイルも消える。

---

## B1 の後

- **B2**：切り替え。local の session を local の daemon で開き、pane を `RemoteMirrorBridge(endpoint: .unix)` で attach する。サイドバー、dot、unread、MacroPad、Save-and-Quit を `session_state` から組み立てる。GUI は shim を作らなくなる。control API の client（`ControlClient`）もここで作る
- **B3**：UI 側に戻す処理（`ContentViewer`、`open_file`、URL、Terminal、アラート、通知、recap の表示、エラーバナー）
- **B4**：daemon 側のサービス（keep-alive、roster、phone からの返信、利用量）
- **B5**：他の Mac の daemon を control API で使う（目標 (a)）
