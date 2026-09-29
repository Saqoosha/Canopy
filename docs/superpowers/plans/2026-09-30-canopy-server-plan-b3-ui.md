# Canopy Server Plan B3 — daemon の session に UI を戻す

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B2 で local の session が daemon に移って失われた UI を戻す。ファイルや出力の表示（`ContentViewer`）、アラート、recap とエラーの表示、通知、keep-alive、permission mode の追従。

**Architecture:** daemon は同じ Mac・同じユーザーの GUI セッションで動くので、「この Mac で開く」処理（`NSWorkspace.open`、Terminal）はそのまま daemon で動く。GUI に戻すのは、pane の webview か GUI の判断が要るものだけ。daemon の `ShimProcess` は、自分の webview を持たないとき（`webView == nil`）、それらを **UI フレーム**（`MirrorUIFrame`）として attach 中の Mac の client に送る。GUI の `RemoteMirrorBridge` がフレームを受け、`MirrorPaneView` が pane の webview で表示する。アラートの答えは逆向きのフレームで daemon に返す。recap の開始は GUI が control verb で頼む。keep-alive は daemon が「client が attach している session」を対象に回す。

**Tech Stack:** Swift 6 / macOS 15、WebKit、UserNotifications。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)。B2 は PR #269。B3 はその上の stacked PR（base: `canopy-server-b2`）。

## Global Constraints

- ブランチ `canopy-server-b3`、PR の base は `canopy-server-b2`、draft
- UI フレームは Mac の client（`MirrorConnection.isMacClient`）にだけ送る。phone に送ると、phone はそれを page に post してしまう
- daemon は `NSAlert.runModal` を呼ばない（main thread が止まり、全 session が止まる）。Mac の client が 1 つも attach していないアラートは、ボタン無し（`NSNull`）で即答する
- 通知：Mac の client が attach していれば client に送り、GUI 側の「前面にいるか」で出すかを決める。1 つもいなければ daemon が自分で出す（GUI を閉じても session は動いているので、それを知らせる手段が要る）
- in-process の shim（`webView` を持つ）の挙動は変えない
- probe の assertion を足したら `EXPECTED_ASSERTIONS` を上げる
- 実機確認は Debug ビルドだけ。window 単位のスクリーンショット、pid 指定のイベント。終わったら Debug の defaults を戻す

## Review Focus

1. **複数の client。** open_file は、それを頼んだ client に表示する（別の Mac に出さない）。recap とエラーは全 Mac client に出す
2. **client がいないとき。** アラートは即答、`ContentViewer` 系は捨ててログ、通知は daemon が出す。どれも daemon を止めない（Task 2 に test）
3. **phone。** UI フレームが phone に届かない（Task 2 に test）
4. **permission mode。** webview で変えた mode が daemon の行（`SessionRow.permissionMode`）に反映され、再 attach 後の表示がそれに一致する（Task 6）
5. **keep-alive の対象。** client が 0 の session には送らない（reaper と同じ「使われていない」の定義）

---

### Task 1: UI フレームの wire（`MirrorUIFrame`）

**Files:**
- Create: `Sources/Canopy/MirrorUIFrame.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `enum MirrorUIFrame: Equatable`
    - `.showContent(title: String, content: String, startLine: Int?, endLine: Int?)`
    - `.evalJS(String)`
    - `.alert(requestId: String, message: String, severity: String, buttons: [String])`
    - `.notify(title: String, body: String)`
  - `MirrorUIFrame.type = "canopy_ui"`、`var wire: [String: Any]`、`init?(wire: [String: Any])`
  - `struct MirrorUIAnswer: Equatable`（`requestId: String`、`button: String?`）、`MirrorUIAnswer.type = "canopy_ui_answer"`、`wire`、`init?(wire:)`

- [ ] **Step 1: 失敗する assertion を書く**（`resume fallback:` の assertion の直後）

```swift
            // Canopy Server UI frames (daemon → Mac client).
            for frame in [MirrorUIFrame.showContent(title: "a.swift", content: "let x = 1", startLine: 3, endLine: 5),
                          .showContent(title: "out", content: "", startLine: nil, endLine: nil),
                          .evalJS("window.x()"),
                          .alert(requestId: "r1", message: "Sure?", severity: "warning", buttons: ["Yes", "No"]),
                          .notify(title: "Canopy", body: "done")] {
                record("ui frame: \(frame) round-trips", MirrorUIFrame(wire: frame.wire) == frame)
            }
            record("ui frame: another type is not a UI frame", MirrorUIFrame(wire: ["type": "status"]) == nil)
            record("ui frame: an unknown action is ignored",
                   MirrorUIFrame(wire: ["type": MirrorUIFrame.type, "action": "explode"]) == nil)
            record("ui answer: a button and no button both round-trip",
                   MirrorUIAnswer(wire: MirrorUIAnswer(requestId: "r1", button: "Yes").wire) == MirrorUIAnswer(requestId: "r1", button: "Yes")
                       && MirrorUIAnswer(wire: MirrorUIAnswer(requestId: "r1", button: nil).wire) == MirrorUIAnswer(requestId: "r1", button: nil))
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 実装する**

```swift
import Foundation

/// UI a daemon session asks its Mac client to show, because the daemon has no
/// pane of its own: a file or output in `ContentViewer`, JavaScript for the
/// pane's page (recap, error banner), an alert, a notification.
enum MirrorUIFrame: Equatable {
    case showContent(title: String, content: String, startLine: Int?, endLine: Int?)
    case evalJS(String)
    case alert(requestId: String, message: String, severity: String, buttons: [String])
    case notify(title: String, body: String)

    static let type = "canopy_ui"

    var wire: [String: Any] {
        var dict: [String: Any] = ["type": Self.type]
        switch self {
        case .showContent(let title, let content, let startLine, let endLine):
            dict["action"] = "show_content"
            dict["title"] = title
            dict["content"] = content
            if let startLine { dict["startLine"] = startLine }
            if let endLine { dict["endLine"] = endLine }
        case .evalJS(let js):
            dict["action"] = "eval_js"
            dict["js"] = js
        case .alert(let requestId, let message, let severity, let buttons):
            dict["action"] = "alert"
            dict["requestId"] = requestId
            dict["message"] = message
            dict["severity"] = severity
            dict["buttons"] = buttons
        case .notify(let title, let body):
            dict["action"] = "notify"
            dict["title"] = title
            dict["body"] = body
        }
        return dict
    }

    init?(wire: [String: Any]) {
        guard wire["type"] as? String == Self.type else { return nil }
        switch wire["action"] as? String {
        case "show_content":
            self = .showContent(title: wire["title"] as? String ?? "", content: wire["content"] as? String ?? "",
                                startLine: wire["startLine"] as? Int, endLine: wire["endLine"] as? Int)
        case "eval_js":
            guard let js = wire["js"] as? String else { return nil }
            self = .evalJS(js)
        case "alert":
            guard let requestId = wire["requestId"] as? String else { return nil }
            self = .alert(requestId: requestId, message: wire["message"] as? String ?? "",
                          severity: wire["severity"] as? String ?? "info", buttons: wire["buttons"] as? [String] ?? [])
        case "notify":
            self = .notify(title: wire["title"] as? String ?? "Canopy", body: wire["body"] as? String ?? "")
        default:
            return nil
        }
    }
}

/// A Mac client's answer to `MirrorUIFrame.alert`; `button` nil is Dismiss.
struct MirrorUIAnswer: Equatable {
    let requestId: String
    let button: String?

    static let type = "canopy_ui_answer"

    var wire: [String: Any] {
        var dict: [String: Any] = ["type": Self.type, "requestId": requestId]
        if let button { dict["button"] = button }
        return dict
    }

    init(requestId: String, button: String?) {
        self.requestId = requestId
        self.button = button
    }

    init?(wire: [String: Any]) {
        guard wire["type"] as? String == Self.type, let requestId = wire["requestId"] as? String else { return nil }
        self.init(requestId: requestId, button: wire["button"] as? String)
    }
}
```

- [ ] **Step 4: ビルドして probe**。8 件 PASS。floor を上げる。

- [ ] **Step 5: Commit**

---

### Task 2: daemon の shim が UI を Mac の client に送る

**Files:**
- Modify: `Sources/Canopy/MirrorSink.swift`（`isMacClient`、`deliverUI`）
- Modify: `Sources/Canopy/MirrorServer.swift`（`MirrorConnection` の実装、`canopy_ui_answer` の受け口）
- Modify: `Sources/Canopy/ShimProcess.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1
- Produces:
  - `MirrorSink.isMacClient: Bool`（既定 false。`MirrorConnection` は既存の `isMacClient` をそのまま使う）、`MirrorSink.isLocalClient: Bool`（既定 false。`MirrorConnection` は `trustsPeer`）、`MirrorSink.deliverUI(_ frame: MirrorUIFrame)`（既定は何もしない）
  - `ShimProcess.uiTarget(requestOwner:clients:) -> Int?`（純粋。頼んだ client が Mac ならそれ、でなければ最初の Mac client。`clients` は `[(isMac: Bool)]` の添字で表す）
  - `ShimProcess.receiveUIAnswer(_ answer: MirrorUIAnswer)`

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            record("ui target: the Mac client that asked gets it",
                   ShimProcess.uiTarget(requester: 1, clients: [true, true]) == 1)
            record("ui target: a phone that asked hands it to the first Mac",
                   ShimProcess.uiTarget(requester: 0, clients: [false, true]) == 1)
            record("ui target: no Mac client, nobody gets it",
                   ShimProcess.uiTarget(requester: 0, clients: [false, false]) == nil)
            record("ui target: no requester, the first Mac client",
                   ShimProcess.uiTarget(requester: nil, clients: [false, true, true]) == 1)
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 純粋関数と sink の口**

`ShimProcess` に（`nonisolated static`）:

```swift
    /// Which attached client shows a UI request: the one that asked, when it is a
    /// Mac; otherwise the first Mac. A phone never gets one (it would post the frame into its page).
    nonisolated static func uiTarget(requester: Int?, clients: [Bool]) -> Int? {
        if let requester, clients.indices.contains(requester), clients[requester] { return requester }
        return clients.firstIndex(of: true)
    }
```

`MirrorSink.swift` の protocol と extension に:

```swift
    /// A Mac's Canopy (not the phone): it can take UI frames.
    var isMacClient: Bool { get }
    /// On this Mac, over the daemon's local socket.
    var isLocalClient: Bool { get }
    func deliverUI(_ frame: MirrorUIFrame)
```

```swift
    var isMacClient: Bool { false }
    var isLocalClient: Bool { false }
    func deliverUI(_ frame: MirrorUIFrame) {}
```

`MirrorConnection` に:

```swift
    var isLocalClient: Bool { trustsPeer }

    func deliverUI(_ frame: MirrorUIFrame) {
        guard isMacClient else { return }
        sendJSONObject(frame.wire)
    }
```

（`isMacClient` は既に `private(set) var` として在る。protocol の要件を満たすので、宣言を変えずに済むか確かめる。）

`handleLineData` の `asset_request` の分岐の後に:

```swift
        if let answer = MirrorUIAnswer(wire: dict) {
            shim?.receiveUIAnswer(answer)
            return
        }
```

- [ ] **Step 4: `ShimProcess` の経路**

`ShimProcess` に、UI を出す先を選ぶ関数を足す:

```swift
    /// The attached Mac that shows a UI request, when this shim has no webview of its own (the daemon).
    private func uiClient(for requestId: String?) -> (any MirrorSink)? {
        let sinks = mirrors.values.compactMap(\.sink)
        var requester: Int?
        if let requestId, case .mirror(let key)? = requestOwners[requestId] {
            requester = sinks.firstIndex { ObjectIdentifier($0) == key }
        }
        return Self.uiTarget(requester: requester, clients: sinks.map(\.isMacClient)).map { sinks[$0] }
    }

    private var macClients: [any MirrorSink] { mirrors.values.compactMap(\.sink).filter(\.isMacClient) }
```

各箇所（`webView == nil` のときだけ変える）:

1. `show_document`：`ContentViewer.show(content:title:in: webView)` の前に
   ```swift
   if webView == nil {
       uiClient(for: nil)?.deliverUI(.showContent(title: fileName, content: content, startLine: nil, endLine: nil))
           ?? logger.notice("show_document dropped: no Mac client attached")
       break
   }
   ```
   （`?? logger` は式として書けないので、`if let client = uiClient(for: nil) { … } else { logger.notice(…) }` にする。）
2. `handleOpenContent`：同じ形で `.showContent`。
3. `handleOpenFile`：既存の「mirror が頼んだときは `MirrorFileSender` で送る」分岐の**前**に、
   ```swift
   if webView == nil, !openExternal, let client = uiClient(for: requestId),
      let content = try? String(contentsOf: resolved, encoding: .utf8) {
       client.deliverUI(.showContent(title: resolved.lastPathComponent, content: content,
                                     startLine: location?["startLine"] as? Int, endLine: location?["endLine"] as? Int))
       // respond and return, as the other branches do
   }
   ```
   テキストでないファイルと Cmd-click（`openExternal`）は、頼んだ client がこの Mac（`isLocalClient`）なら daemon がそのまま `NSWorkspace.open`（同じ画面）。他の Mac なら今の `MirrorFileSender` の分岐に任せる。
4. `showRecapInWebView`：`guard let webView else { … }` の中で、
   ```swift
   let call = text.map { RecapScript.setCall(text: $0) } ?? RecapScript.clearCall
   let js = "(window.__canopyRecap ? (\(call), 'ok') : 'no-bridge')"
   let clients = macClients
   if clients.isEmpty { if text != nil { logger.error("recap dropped: no webview and no Mac client") } }
   clients.forEach { $0.deliverUI(.evalJS(js)) }
   return
   ```
5. `showErrorInWebView`：同様に、組み立てた JS を `macClients` に `.evalJS` で送る（`boundSession?.lastFatalError` の記録は今のまま）。
6. `handleNotification`（アラート）：先頭に
   ```swift
   if webView == nil {
       guard let client = uiClient(for: nil) else {
           // Never a modal in the daemon: it would stop every session. No Mac to ask means Dismiss.
           sendToShim(["type": "notification_response", "requestId": requestId, "buttonValue": NSNull()])
           return
       }
       client.deliverUI(.alert(requestId: requestId, message: message, severity: severity, buttons: buttons))
       return
   }
   ```
   `receiveUIAnswer`:
   ```swift
   func receiveUIAnswer(_ answer: MirrorUIAnswer) {
       sendToShim(["type": "notification_response", "requestId": answer.requestId,
                   "buttonValue": answer.button.map { $0 as Any } ?? NSNull()])
   }
   ```
7. `postTaskCompletedNotification`：`guard !NSApp.isActive else { return }` の前に
   ```swift
   if webView == nil, !macClients.isEmpty {
       // The GUI decides whether it is frontmost; the daemon's own `isActive` means nothing.
       macClients.forEach { $0.deliverUI(.notify(title: "Canopy", body: body)) }
       return
   }
   ```
   （client がいなければ、下の既存のコードが daemon から通知を出す。daemon は accessory なので `NSApp.isActive` は常に false で、必ず出る。）

- [ ] **Step 5: ビルドして probe**。4 件 PASS。floor を上げる。

- [ ] **Step 6: Commit**

---

### Task 3: GUI が UI フレームを表示する

**Files:**
- Modify: `Sources/Canopy/MirrorClient.swift`（`RemoteMirrorBridge`）
- Modify: `Sources/Canopy/MirrorPaneView.swift`

**Interfaces:**
- Consumes: Task 1
- Produces:
  - `RemoteMirrorBridge.onUIFrame: ((MirrorUIFrame) -> Void)?`
  - `RemoteMirrorBridge.sendUIAnswer(_ answer: MirrorUIAnswer)`

- [ ] **Step 1: bridge が受け、答えを送る**

受信した行を振り分けている箇所（`onStatus` / `onUsage` / `onFileFrame` を呼んでいる所）に:

```swift
            if let frame = MirrorUIFrame(wire: dict) {
                onUIFrame?(frame)
                return
            }
```

```swift
    func sendUIAnswer(_ answer: MirrorUIAnswer) {
        sendJSONObject(answer.wire)
    }
```

- [ ] **Step 2: pane が表示する**

`MirrorPaneView.attachBridge` で:

```swift
        bridge.onUIFrame = { [weak session, weak bridge, weak webView] frame in
            guard let session else { return }
            switch frame {
            case .showContent(let title, let content, let startLine, let endLine):
                ContentViewer.show(content: content, title: title, in: webView, startLine: startLine, endLine: endLine)
            case .evalJS(let js):
                webView?.evaluateJavaScript(js, completionHandler: nil)
            case .alert(let requestId, let message, let severity, let buttons):
                let alert = NSAlert()
                alert.messageText = message
                alert.alertStyle = severity == "error" ? .critical : severity == "warning" ? .warning : .informational
                buttons.forEach { alert.addButton(withTitle: $0) }
                alert.addButton(withTitle: "Dismiss")
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                bridge?.sendUIAnswer(MirrorUIAnswer(requestId: requestId, button: index < buttons.count ? buttons[index] : nil))
            case .notify(let title, let body):
                guard !NSApp.isActive else { return }
                SessionNotifier.post(title: title, body: body)
            }
            _ = session
        }
```

`ContentViewer.show` の `startLine` / `endLine` 付きの形が `ShimProcess.handleOpenFile` と同じ引数であることを確かめる。`SessionNotifier.post` は、`ShimProcess.postTaskCompletedNotification` の末尾の `UNMutableNotificationContent` … `UNUserNotificationCenter.current().add` を切り出した小さな enum にして、両方から呼ぶ。

- [ ] **Step 3: ビルドして probe**。failed 0。

- [ ] **Step 4: Commit**

---

### Task 4: recap を daemon の pane にも

**Files:**
- Modify: `Sources/Canopy/ControlSession.swift`（`request_recap` verb）
- Modify: `Sources/Canopy/RecapCoordinator.swift`

**Interfaces:**
- Consumes: B1 の `requestedSession`、`ShimProcess.recapIneligibilityReason` / `requestRecap()`
- Produces（wire）: `request_recap {key | sessionId}` → `{requested: Bool, reason?: String}`

- [ ] **Step 1: verb**

```swift
        case "request_recap": requestRecap(request)
```

```swift
    private func requestRecap(_ request: ControlProtocol.Request) {
        guard let session = requestedSession(request) else { return }
        guard let shim = session.shim else {
            reply(request, ["requested": false, "reason": "not running"])
            return
        }
        if let reason = shim.recapIneligibilityReason {
            reply(request, ["requested": false, "reason": reason])
            return
        }
        shim.requestRecap()
        reply(request, ["requested": true])
    }
```

- [ ] **Step 2: coordinator**

`RecapCoordinator.fire()` の pane のループで、`session.shim` が nil のとき:

```swift
            if session.isDaemonHosted, let control = store.daemonControl {
                let params = SessionStore.daemonRefParams(session)
                Task {
                    switch await control.request("request_recap", params) {
                    case .success(let result):
                        if result["requested"] as? Bool != true {
                            logger.info("pane \(index, privacy: .public): daemon skipped recap — \(result["reason"] as? String ?? "?", privacy: .public)")
                        }
                    case .failure(let failure):
                        logger.error("pane \(index, privacy: .public): request_recap failed: \(String(describing: failure), privacy: .public)")
                    }
                }
                requested += 1
                continue
            }
```

（`guard let session …, let shim = session.shim else { … }` を、`session` だけの guard と、shim の有無の分岐に分ける。）

- [ ] **Step 3: ビルドして probe**。

- [ ] **Step 4: Commit**

---

### Task 5: keep-alive を daemon で回す

**Files:**
- Modify: `Sources/Canopy/KeepAliveCoordinator.swift`
- Modify: `Sources/Canopy/CanopyDaemon.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `KeepAliveCoordinator.targets: (SessionStore) -> [(label: String, session: OpenSession)]`（既定は今の「pane にある session」）
  - `KeepAliveCoordinator.daemonTargets(_ sessions: [OpenSession]) -> [OpenSession]`（純粋に近い：shim があり `mirrorCount > 0` のもの）

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            do {
                let tmp = URL(fileURLWithPath: "/tmp")
                let none = OpenSession(origin: .local(tmp), resumeId: "a", title: "", project: "")
                record("keep-alive (daemon): a session with no shim is not a target",
                       KeepAliveCoordinator.daemonTargets([none]).isEmpty)
            }
```

（shim を持つ fixture は probe で作れないので、「shim が無いものは対象外」だけを固定する。`mirrorCount > 0` の条件は Task 7 の実機確認で見る。）

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 実装する**

```swift
    /// The daemon's sessions worth keeping warm: running, with a client attached.
    /// It has no panes; an attached client is its "someone is coming back".
    static func daemonTargets(_ sessions: [OpenSession]) -> [OpenSession] {
        sessions.filter { ($0.shim?.mirrorCount ?? 0) > 0 }
    }

    /// Where `tick` looks. The GUI keeps the pane scope; the daemon sets `daemonTargets`.
    var targets: (SessionStore) -> [(label: String, session: OpenSession)] = { store in
        store.panes.enumerated().compactMap { index, pane in
            guard case .session(let id) = pane.content,
                  let session = store.openSessions.first(where: { $0.id == id }) else { return nil }
            return ("pane \(index)", session)
        }
    }
```

`tick()` のループを `for (label, session) in targets(store) { guard let shim = session.shim else { continue } … }` にして、ログの `pane \(index)` を `\(label)` にする。`sessionPanes` の数え方も `targets(store).count` にする。

`CanopyDaemon` の `applicationDidFinishLaunching` で:

```swift
        KeepAliveCoordinator.shared.targets = { store in
            KeepAliveCoordinator.daemonTargets(store.openSessions).map { ("session \($0.resumeId.prefix(8))", $0) }
        }
        KeepAliveCoordinator.shared.start()
```

`SessionStore.shared` が daemon の store を指していることを確かめる（`SessionStore()` の init で `shared` が設定されるか）。されていなければ、`KeepAliveCoordinator` に store を渡す口を足す。

- [ ] **Step 4: ビルドして probe**。1 件 PASS。floor を上げる。

- [ ] **Step 5: Commit**

---

### Task 6: permission mode の追従

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift`（`handleWebviewMessage`）
- Modify: `Sources/Canopy/SessionStore.swift`（`applyDaemonSessions`）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces: `ShimProcess.requestedPermissionMode(_ message: [String: Any]) -> PermissionMode?`（純粋。`{type: "request", request: {type: "set_permission_mode", mode}}` から mode を取り出す）

- [ ] **Step 1: 失敗する assertion を書く**

```swift
            record("permission mode: set_permission_mode is read",
                   ShimProcess.requestedPermissionMode(["type": "request", "request": ["type": "set_permission_mode", "mode": "plan", "userInitiated": true]]) == .plan)
            record("permission mode: another request is not",
                   ShimProcess.requestedPermissionMode(["type": "request", "request": ["type": "list_sessions_request"]]) == nil)
            record("permission mode: an unknown mode is not",
                   ShimProcess.requestedPermissionMode(["type": "request", "request": ["type": "set_permission_mode", "mode": "yolo"]]) == nil)
```

- [ ] **Step 2: ビルドして失敗を確かめる**。

- [ ] **Step 3: 実装する**

```swift
    /// The mode a webview asks for (extension 2.1.283's `set_permission_mode` request), or nil.
    nonisolated static func requestedPermissionMode(_ message: [String: Any]) -> PermissionMode? {
        guard message["type"] as? String == "request",
              let request = message["request"] as? [String: Any],
              request["type"] as? String == "set_permission_mode",
              let raw = request["mode"] as? String else { return nil }
        return PermissionMode(rawValue: raw)
    }
```

`handleWebviewMessage` の先頭（`var dict = incoming` の直後）:

```swift
        if let mode = Self.requestedPermissionMode(incoming) {
            // Kept so a later attach's synthetic status and the daemon's session row show the live mode.
            permissionMode = mode
            boundSession?.permissionMode = mode
        }
```

`applyDaemonSessions` の update で:

```swift
            if let mode = PermissionMode(rawValue: row.permissionMode), mode != session.permissionMode {
                session.permissionMode = mode
            }
```

`ShimProcess.permissionMode` が `let` なら `var` にする。

- [ ] **Step 4: ビルドして probe**。3 件 PASS。floor を上げる。

- [ ] **Step 5: Commit**

---

### Task 7: 実機で確かめる（Debug ビルド）

B2 の Task 10 と同じ方法（snapshot を植える、pid 指定のイベント、window 単位のスクリーンショット）。

- [ ] **Step 1: ファイル表示**：transcript のファイルリンク（Read した行）をクリックし、pane に `ContentViewer` が出る
- [ ] **Step 2: permission mode**：composer の mode を切り替え、`list_sessions` の `permissionMode` が変わり、Cmd+W → 再 attach 後の表示が一致する
- [ ] **Step 3: 通知**：GUI を背面にした状態で短い prompt を送り、完了通知が出る（GUI から）
- [ ] **Step 4: recap**：`CANOPY_RECAP_DELAY_SECONDS=5` で GUI を起動し、背面に回して戻ると recap が出る（有効化されていれば）
- [ ] **Step 5: 後片付け**

---

## B3 に入れないもの

- phone と roster、利用量 → B4
- 他の Mac から daemon へ → B5
- アラートを複数の Mac client に同時に出す（最初の 1 つだけ）
