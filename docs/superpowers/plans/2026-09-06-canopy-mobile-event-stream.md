# Canopy Mobile Event Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone で、開いているセッションの会話（アシスタント発言・ユーザー発言・ツール名）をライブで読めるようにする。

**Architecture:** Canopy の `ShimProcess` が io_message から `SessionEvent` を作り、既存の roster publisher WebSocket で relay に送る。relay の `MachineDO` が seq を採番して SQLite のリングバッファに追記し、watcher へ fan-out する。iPhone は seq で再開・重複排除し、既存の通知履歴と時刻順に合成して描画する。

**Tech Stack:** Swift 6 / SwiftUI（Canopy, iOS app）、Cloudflare Workers + Durable Objects（SQLite backed）、vitest、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-09-06-canopy-mobile-event-stream-design.md`

## Global Constraints

- リポジトリは 2 つ。Canopy = `/Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream`（この worktree）、Canopy-Mobile = `/Users/hiko/repos/Personal/Canopy-Mobile`。
- **ダークモードを実装しない。** 単一パレット。
- 上限は spec のとおり：1 セッション 200 イベント、保持セッション 20、1 イベントのテキスト 8 KB。
- ツールの引数・コマンド文字列・パス・差分・実行結果は relay に送らない。ツール名のみ。
- **CI の floor は測ってから書く。** `EXPECTED_TESTS`（現在 42）と `EXPECTED_SWIFT_TESTS`（現在 54）は `.github/workflows/ci.yml`、`EXPECTED_ASSERTIONS` は Canopy の `.github/workflows/ci.yml`。計算で出した数を書かない。
- Canopy-Mobile の worker テストは `cd worker && npx tsc --noEmit` を**必ずテストの前に**通す。CI は tsc → tests の順で、テストが緑でも型で落ちる。
- 日本語の見出しは体言止め。太字の閉じ `**` の直前に `。、」）` を置かない。
- コミットは各タスクの最後。**push と PR 作成はしない**（人間の指示を待つ）。

### 測定済みの前提（推測ではない）

- **CLI は `--resume` で過去の `assistant` フレームを個別に再生しない。** CLI 2.1.258 に Canopy と同じフラグ（`-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --resume <id>`）で 2 回測定し、どちらも新しい turn のフレームのみだった。セッション履歴の再生は `response.messages` の**配列 1 通**として届き、`ShimProcess.strippingRecapFromReplay` がその形を扱っている。したがって個別フレームに引っ掛ける抽出器は、セッションを開いても履歴を流し込まない。
- `NotificationHistoryItem.id` は NSE がローカルで `UUID().uuidString` から作る（`Sources/CanopyMobileNotificationService/NotificationService.swift:61`）。Canopy とは共有されないので、経路をまたぐ重複排除には別途 `eventId` が要る。
- `MachineDO` は SQLite backed（`worker/wrangler.toml` の `new_sqlite_classes`）で、`ctx.storage.sql` の `snapshot` テーブルを既に持つ。
- roster のスナップショット JSON は `type` フィールドを持たない。`type` の有無が snapshot と event の判別に使える（DO 側・電話側とも）。

---

## ファイル構成

**Canopy（この worktree）**

| ファイル | 責務 |
|---|---|
| `Sources/Canopy/Roster/SessionEvent.swift`（新規） | イベントの値型と、io_message からの**純粋な**抽出関数 |
| `Sources/Canopy/Roster/RosterPublisher.swift`（変更） | `sendEvent(_:)` — 既存ソケットへの送信 |
| `Sources/Canopy/ShimProcess.swift`（変更） | 抽出のフック、`eventId` を completed push に載せる |
| `Sources/Canopy/Roster/RosterNotifier.swift`（変更） | `post(... eventId:)` |
| `Sources/Canopy/_SidebarLogicProbe.swift`（変更） | 抽出規則のアサーション |

**Canopy-Mobile**

| ファイル | 責務 |
|---|---|
| `worker/src/types.ts`（変更） | `SessionEventMessage`, `EventsSinceRequest`, `EventsResponse` |
| `worker/src/machine.ts`（変更） | `event` テーブル、seq 採番、トリム、fan-out、バックフィル応答 |
| `worker/src/machine.test.ts`（変更） | DO のテスト |
| `Sources/SessionEventStore.swift`（新規） | 受信イベントの保持・順序・重複排除・lastSeq |
| `Sources/RosterSocket.swift`（変更） | snapshot と event の判別、`events_since` 送信 |
| `Sources/Shared/NotificationHistoryItem.swift`（変更） | `eventId` フィールド |
| `Sources/CanopyMobileNotificationService/NotificationService.swift`（変更） | `userInfo["eventId"]` の取り込み |
| `Sources/SessionConversationView.swift`（変更） | 合成と重複排除 |
| `Tests/SessionEventTests.swift`（新規） | ストア・合成のテスト |

---

## Task 1: SessionEvent の値型と抽出規則

**Files:**
- Create: `Sources/Canopy/Roster/SessionEvent.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`
- Modify: `.github/workflows/ci.yml`（`EXPECTED_ASSERTIONS`）

**Interfaces:**
- Consumes: なし（このタスクが最初）
- Produces:
  - `struct SessionEvent: Codable, Equatable, Sendable`（フィールド：`type: String`（常に `"event"`）、`eventId: String`、`sessionId: String`、`resumeId: String?`、`kind: SessionEvent.Kind`、`text: String`、`at: Date`）
  - `enum SessionEvent.Kind: String, Codable, Sendable { case assistant, user, tool, turnStart, turnEnd }`
  - `static func SessionEvent.events(from message: [String: Any], sessionId: String, resumeId: String?, at: Date, nextId: () -> String) -> [SessionEvent]`
  - `static let SessionEvent.maxTextBytes = 8 * 1024`

- [ ] **Step 1: 失敗するアサーションを probe に書く**

`Sources/Canopy/_SidebarLogicProbe.swift` の `runAllTests()` 末尾付近（他の値型ブロックと同じ並び）に追加する。`check(_:_:)` はこのファイルの既存ヘルパ。

```swift
// MARK: - session event extraction
do {
    var n = 0
    let ids = { () -> String in n += 1; return "e\(n)" }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // assistant: text ブロックだけを繋ぐ。thinking は落とす。
    let assistant: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "thinking", "thinking": "secret"],
            ["type": "text", "text": "hello"],
            ["type": "text", "text": "world"],
        ]],
    ]
    let a = SessionEvent.events(from: assistant, sessionId: "S", resumeId: "R", at: now, nextId: ids)
    check("event: assistant joins text blocks", a.count == 1 && a[0].kind == .assistant && a[0].text == "hello\nworld")
    check("event: assistant drops thinking", !a[0].text.contains("secret"))

    // tool_use: 名前＋列挙されたフィールドだけ。
    let bash: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "tool_use", "name": "Bash", "input": ["command": "npm test\nsecond line"]],
        ]],
    ]
    let t = SessionEvent.events(from: bash, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: tool_use becomes one tool event", t.count == 1 && t[0].kind == .tool)
    check("event: Bash carries its first command line", t[0].text == "Bash: npm test")
    check("event: Bash carries only the first line", !t[0].text.contains("second line"))

    // Read/Edit/Write: ファイル名のみ。ディレクトリは落とす。
    let edit: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/hiko/secret/SessionStore.swift"]],
        ]],
    ]
    let e = SessionEvent.events(from: edit, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: Edit carries the file name", e[0].text == "Edit: SessionStore.swift")
    check("event: Edit drops the directory", !e[0].text.contains("/Users/hiko"))

    // 列挙にないツールは名前だけ。既定がこれであることが漏洩を防ぐ。
    let unknown: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "tool_use", "name": "WebFetch", "input": ["url": "https://internal.example/secret"]],
        ]],
    ]
    let w = SessionEvent.events(from: unknown, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: an unlisted tool is the name alone", w[0].text == "WebFetch")
    check("event: an unlisted tool leaks no input", !w[0].text.contains("internal.example"))

    // 長い要約は 80 文字で切る。
    let longCmd: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "tool_use", "name": "Bash", "input": ["command": String(repeating: "x", count: 200)]],
        ]],
    ]
    let l = SessionEvent.events(from: longCmd, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: a long summary is capped", l[0].text.count <= "Bash: ".count + 81)

    // user: tool_result を含むフレームは会話ではない。
    let toolResult: [String: Any] = [
        "type": "user",
        "message": ["content": [["type": "tool_result", "content": "12345 files"]]],
    ]
    check("event: user frame carrying tool_result is skipped",
          SessionEvent.events(from: toolResult, sessionId: "S", resumeId: nil, at: now, nextId: ids).isEmpty)

    let realUser: [String: Any] = [
        "type": "user",
        "message": ["content": [["type": "text", "text": "do it"]]],
    ]
    let u = SessionEvent.events(from: realUser, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: a genuine user turn is kept", u.count == 1 && u[0].kind == .user && u[0].text == "do it")

    // 混在フレーム: tool_result が 1 つでもあれば会話ではない。
    let mixed: [String: Any] = [
        "type": "user",
        "message": ["content": [
            ["type": "text", "text": "and also"],
            ["type": "tool_result", "content": "output"],
        ]],
    ]
    check("event: a mixed user frame with any tool_result is skipped",
          SessionEvent.events(from: mixed, sessionId: "S", resumeId: nil, at: now, nextId: ids).isEmpty)

    // turn の境界。
    let initFrame: [String: Any] = ["type": "system", "subtype": "init"]
    let resultFrame: [String: Any] = ["type": "result", "subtype": "success"]
    check("event: system/init is a turn start",
          SessionEvent.events(from: initFrame, sessionId: "S", resumeId: nil, at: now, nextId: ids)
              .first?.kind == .turnStart)
    check("event: result is a turn end",
          SessionEvent.events(from: resultFrame, sessionId: "S", resumeId: nil, at: now, nextId: ids)
              .first?.kind == .turnEnd)

    // 無関係なフレームは何も生まない。
    check("event: stream_event produces nothing",
          SessionEvent.events(from: ["type": "stream_event"], sessionId: "S", resumeId: nil, at: now, nextId: ids).isEmpty)

    // 履歴の一括再生（response.messages の形）は 1 件も生まない。
    let replay: [String: Any] = [
        "type": "get_session_response",
        "response": ["messages": [["type": "assistant", "message": ["content": [["type": "text", "text": "old"]]]]]],
    ]
    check("event: a bulk replay envelope produces nothing",
          SessionEvent.events(from: replay, sessionId: "S", resumeId: nil, at: now, nextId: ids).isEmpty)

    // 8 KB 上限。
    let huge = String(repeating: "あ", count: 20_000)  // UTF-8 で 60,000 バイト
    let big: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": huge]]]]
    let b = SessionEvent.events(from: big, sessionId: "S", resumeId: nil, at: now, nextId: ids)
    check("event: text is capped at maxTextBytes",
          b[0].text.utf8.count <= SessionEvent.maxTextBytes)
    check("event: a capped text is marked", b[0].text.hasSuffix("…"))

    // id は与えられたファクトリから来る（採番は呼び出し側の責務）。
    let two: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "text", "text": "x"],
            ["type": "tool_use", "name": "Read", "input": [:]],
        ]],
    ]
    var m = 0
    let seqIds = { () -> String in m += 1; return "id\(m)" }
    let pair = SessionEvent.events(from: two, sessionId: "S", resumeId: nil, at: now, nextId: seqIds)
    check("event: each event gets its own id", pair.count == 2 && pair[0].eventId == "id1" && pair[1].eventId == "id2")

    // 空のテキストはイベントにしない。
    let empty: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": "   "]]]]
    check("event: an empty assistant text produces nothing",
          SessionEvent.events(from: empty, sessionId: "S", resumeId: nil, at: now, nextId: ids).isEmpty)
}
```

- [ ] **Step 2: 走らせて落ちることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream
./scripts/build_debug_stable.sh
```

Expected: コンパイルエラー `cannot find 'SessionEvent' in scope`。

- [ ] **Step 3: SessionEvent.swift を書く**

```swift
import Foundation

/// 電話に流す 1 件の出来事。
///
/// **`type` を持つのが roster のスナップショットとの唯一の違いである。**
/// スナップショットは `type` を持たないので、DO も電話もこのフィールドの
/// 有無だけで両者を判別できる。フィールドを消すと、どちらの側でも
/// スナップショットとして解釈され、静かに落ちる。
struct SessionEvent: Codable, Equatable, Sendable {
    /// 常に `"event"`。上のコメントの理由で定数。
    let type: String
    /// Canopy が振る id。**DO の `seq` とは役割が違う** — こちらは
    /// completed push にも載り、経路をまたいだ同一性に使う。
    let eventId: String
    let sessionId: String
    let resumeId: String?
    let kind: Kind
    let text: String
    let at: Date

    enum Kind: String, Codable, Sendable {
        case assistant
        case user
        case tool
        case turnStart
        case turnEnd
    }

    /// 1 イベントのテキスト上限（バイト）。DO の 1 行が肥大しないための上限。
    static let maxTextBytes = 8 * 1024

    init(eventId: String, sessionId: String, resumeId: String?, kind: Kind, text: String, at: Date) {
        self.type = "event"
        self.eventId = eventId
        self.sessionId = sessionId
        self.resumeId = resumeId
        self.kind = kind
        self.text = text
        self.at = at
    }

    /// io_message 1 通から 0 件以上のイベントを作る。純粋関数。
    ///
    /// **`user` フレームの大半は tool_result である。**`content` に
    /// `tool_result` が 1 つでもあれば会話ではないので落とす。ここを落とすと
    /// 電話の会話がツール結果で埋まる。
    ///
    /// 一括再生（`response.messages` の配列）はここに来ても何も生まない。
    /// 個別フレームの `type` しか見ないので、再生の封筒は素通りする。
    static func events(from message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String) -> [SessionEvent] {
        func make(_ kind: Kind, _ text: String) -> SessionEvent? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionEvent(eventId: nextId(), sessionId: sessionId, resumeId: resumeId,
                                kind: kind, text: capped(trimmed), at: at)
        }

        switch message["type"] as? String {
        case "assistant":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var out: [SessionEvent] = []
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if let event = make(.assistant, text) { out.append(event) }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String,
                      let event = make(.tool, toolLabel(name: name, input: block["input"] as? [String: Any]))
                else { continue }
                out.append(event)
            }
            return out

        case "user":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return [] }
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return [make(.user, text)].compactMap { $0 }

        case "system":
            guard message["subtype"] as? String == "init" else { return [] }
            return [make(.turnStart, "start")].compactMap { $0 }

        case "result":
            return [make(.turnEnd, "end")].compactMap { $0 }

        default:
            return []
        }
    }

    /// ツール 1 件の表示ラベル。
    ///
    /// **既定は名前だけで、要約を出すツールはここに列挙したものに限る。**
    /// 逆（既定で `input` を出し、危ないものを除外する）にしてはいけない —
    /// 新しいツールが増えるたびに、誰も気づかないまま中身が relay に出る。
    /// 列挙を減らす方向は常に安全で、増やす方向だけが判断を要する。
    private static func toolLabel(name: String, input: [String: Any]?) -> String {
        func short(_ value: String?) -> String? {
            guard let value, let line = value.split(separator: "\n").first else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        }
        let summary: String?
        switch name {
        case "Bash":
            summary = short(input?["command"] as? String)
        case "Read", "Edit", "Write":
            // ファイル名のみ。ディレクトリはマシンの構造そのものなので落とす。
            summary = short((input?["file_path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            })
        case "Glob", "Grep":
            summary = short(input?["pattern"] as? String)
        case "Task", "Agent":
            summary = short(input?["description"] as? String)
        default:
            summary = nil
        }
        guard let summary else { return name }
        return "\(name): \(summary)"
    }

    /// UTF-8 バイト数で切る。文字数ではない — DO に入るのはバイトであり、
    /// 日本語なら 1 文字 3 バイトなので、文字数の上限は上限にならない。
    private static func capped(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var out = text
        // 末尾の「…」の分を空けて縮める。Character 単位で削るので
        // サロゲートペアの途中で切れることがない。
        while out.utf8.count > maxTextBytes - 3, !out.isEmpty {
            out.removeLast()
        }
        return out + "…"
    }
}
```

- [ ] **Step 4: probe を走らせて通ることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: `--- N passed` で失敗 0。

- [ ] **Step 5: 変異テストで実効性を確認する**

`events(from:)` の `user` ケースの `guard !blocks.contains(...)` を消して probe を再実行する。`event: user frame carrying tool_result is skipped` と `event: a mixed user frame with any tool_result is skipped` の 2 本が落ちること。確認したら元に戻して再度緑を確認する。

- [ ] **Step 6: CI の floor を測って上げる**

probe の出力の `--- N passed` を読み、その **N を** `.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS` に書く。計算しない。

- [ ] **Step 7: commit**

```bash
git add Sources/Canopy/Roster/SessionEvent.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Extract session events from the io_message stream"
```

---

## Task 2: 送信と、completed push への eventId 付与

**Files:**
- Modify: `Sources/Canopy/Roster/RosterPublisher.swift`
- Modify: `Sources/Canopy/Roster/RosterNotifier.swift`
- Modify: `Sources/Canopy/ShimProcess.swift`

**Interfaces:**
- Consumes: `SessionEvent`, `SessionEvent.events(from:sessionId:resumeId:at:nextId:)`（Task 1）
- Produces:
  - `func RosterPublisher.sendEvent(_ event: SessionEvent)`（`@MainActor`）
  - `RosterNotifier.post` に `eventId: String? = nil` 引数が増える
  - `ShimProcess` の `private var lastAssistantEventId: String?`

- [ ] **Step 1: RosterPublisher に送信口を足す**

`publish()` の直後に置く。

```swift
    /// 1 件のイベントを既存のソケットに流す。
    ///
    /// **ソケットが無ければ黙って捨てる。** Mac 側にバッファを置いて
    /// 再接続後に流し直すことは意図的にしない — バッファは DO 側に置く
    /// 設計であり、両側に置くのは保険の二重掛けで、DO に置いた意味を消す。
    /// 切断中のイベントが失われるのは受け入れた欠点である（spec 参照）。
    ///
    /// 再接続もここでは駆動しない。`publish()` が pane の変化で走るときに
    /// 繋ぎ直す。イベントの送信失敗で reconnect を始めると、1 turn に数十件
    /// 来るイベントが reconnect を何度も叩くことになる。
    func sendEvent(_ event: SessionEvent) {
        guard settings.rosterEnabled, let task else { return }
        guard let data = try? JSONEncoder().encode(event),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.logger.debug("roster: event send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
```

`JSONEncoder` の日付は既定で `Double`（referenceDate 起点）になる。DO 側は数値としてしか扱わないので変換は不要だが、電話側の `JSONDecoder` と揃える必要がある。**エンコーダとデコーダの日付戦略を揃えること**は Task 5 の受け入れ条件に含める。

- [ ] **Step 2: RosterNotifier.post に eventId を通す**

`post` の引数リストに `eventId: String? = nil` を足し、JSON body を組む箇所に次を加える。

```swift
        if let eventId { body["eventId"] = eventId }
```

- [ ] **Step 3: ShimProcess にフックを入れる**

`ShimProcess.swift` の io_message 分岐、`extractRawUsage(innerMessage)` の直後（`isCanopyOwnedResponse` の手前）に 1 行足す。

```swift
            publishSessionEvents(innerMessage)
```

**この位置である理由**：`consumeRecapTraffic` と `consumeKeepAliveTraffic` の後ろなので、recap と keep-alive の合成 turn は流れない。両者はユーザーが起こしたものではなく、電話に見せるものではない。

そして同ファイルに実装を足す。

```swift
    /// この turn で最後に流した assistant イベントの id。
    /// completed push に載せ、電話が同じ内容を二重に描画しないようにする。
    private var lastAssistantEventId: String?

    /// io_message 1 通を電話向けのイベントに変換して送る。
    ///
    /// 履歴の一括再生はここを通らない。再生は `response.messages` の配列
    /// 1 通として届き、`SessionEvent.events` は個別フレームの `type` しか
    /// 見ないので何も生まない（CLI 2.1.258 で測定済み、spec 参照）。
    private func publishSessionEvents(_ message: [String: Any]) {
        guard let session = boundSession else { return }
        let events = SessionEvent.events(from: message,
                                         sessionId: session.id.uuidString,
                                         resumeId: session.resumeId,
                                         at: Date(),
                                         nextId: { UUID().uuidString })
        guard !events.isEmpty else { return }
        for event in events {
            if event.kind == .assistant { lastAssistantEventId = event.eventId }
            RosterPublisher.current?.sendEvent(event)
        }
    }
```

**`RosterPublisher` に静的なアクセサは存在しない**。`SessionStore` と `CanopySettings` を受け取って構築される `@MainActor final class` で、インスタンスは呼び出し側（`CanopyApp` / `AppDelegate`）が保持している。`ShimProcess` からは届かない。

だから Task 2 はアクセサを 1 つ足す。`MacroPadStatus` が「controller は AppDelegate が持っていて observable ではないので、別に singleton を置く」という同じ形を先に採っており、それに倣う。

```swift
    /// `ShimProcess` から届く唯一の口。**弱参照である** — 所有者は
    /// このクラスを構築した側（`CanopyApp` / `AppDelegate`）であり、
    /// ここが強く持つと二重所有になる。イベントは落としてよい種類の
    /// データなので、nil のときは黙って捨てるのが正しい。
    static weak var current: RosterPublisher?
```

`init` の末尾に `Self.current = self` を書く。`ShimProcess` 側は `RosterPublisher.current?.sendEvent(event)` と呼ぶ。

**構築箇所は実装時に確認すること** — `Sources/Canopy` を `RosterPublisher(` で検索すれば 1 箇所で見つかる。この計画を書いた時点では Bash が使えず、その 1 箇所を目で確認できていない。

- [ ] **Step 4: completed push に載せる**

`postTaskCompletedNotification(finalText:)` の `RosterNotifier.post(...)` 呼び出しに引数を 1 つ足す。

```swift
                                bodyFull: finalText,
                                eventId: lastAssistantEventId)
```

- [ ] **Step 5: ビルドして probe が緑のままか確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: BUILD SUCCEEDED、probe の失敗 0。

- [ ] **Step 6: 実機で洪水が起きないことを確認する**

Debug ビルドを起動し、**既に履歴のあるセッションを開く**。ログを読む。

```bash
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "Roster"' --last 3m --style compact | /usr/bin/tail -20
```

Expected: セッションを開いただけでは event の送信が起きない（履歴の件数ぶんのイベントが流れない）。1 turn 走らせると数件〜数十件流れる。**この確認は測定であり、飛ばしてはいけない** — 前提が外れていた場合、DO に履歴が丸ごと流れ込む。

- [ ] **Step 7: commit**

```bash
git add Sources/Canopy/Roster/RosterPublisher.swift Sources/Canopy/Roster/RosterNotifier.swift Sources/Canopy/ShimProcess.swift
git commit -m "Send session events over the roster socket"
```

---

## Task 3: DO のリングバッファ（取り込み・採番・トリム・配信）

**Files:**
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/worker/src/types.ts`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/worker/src/machine.ts`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/worker/src/machine.test.ts`

**Interfaces:**
- Consumes: Canopy が送る `{type:"event", eventId, sessionId, resumeId, kind, text, at}`（Task 2）
- Produces:
  - `interface SessionEventMessage`（`types.ts`）
  - `MachineDO.appendEvent(msg: SessionEventMessage): number | null` — 採番した seq、拒否なら null
  - watcher に配る形：`{type:"event", seq, eventId, sessionId, resumeId, kind, text, at}`
  - 定数 `MachineDO.maxEventsPerSession = 200`、`MachineDO.maxSessions = 20`

- [ ] **Step 1: 失敗するテストを書く**

`worker/src/machine.test.ts` に追記する。既存のテストが `runInDurableObject` を使っていればそれに合わせ、使っていなければ次の形で新規に足す。

```ts
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";

function ev(sessionId: string, text: string) {
  return {
    type: "event" as const,
    eventId: `${sessionId}-${text}`,
    sessionId,
    resumeId: null,
    kind: "assistant" as const,
    text,
    at: 0,
  };
}

describe("event ring buffer", () => {
  it("assigns strictly increasing seq", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:seq-test"));
    await runInDurableObject(stub, async (instance) => {
      const a = instance.appendEvent(ev("s1", "one"));
      const b = instance.appendEvent(ev("s1", "two"));
      expect(a).not.toBeNull();
      expect(b).not.toBeNull();
      expect(b!).toBeGreaterThan(a!);
    });
  });

  it("keeps the newest events when the per-session cap is passed", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:trim-test"));
    await runInDurableObject(stub, async (instance) => {
      for (let i = 0; i < 205; i++) instance.appendEvent(ev("s1", `t${i}`));
      const rows = instance.eventsSince("s1", 0);
      expect(rows.events.length).toBe(200);
      // 新しい方が残る。古い t0 は消えている。
      expect(rows.events.some((e) => e.text === "t204")).toBe(true);
      expect(rows.events.some((e) => e.text === "t0")).toBe(false);
    });
  });

  it("reports the oldest seq it still holds so the phone can see a gap", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:gap-test"));
    await runInDurableObject(stub, async (instance) => {
      for (let i = 0; i < 205; i++) instance.appendEvent(ev("s1", `t${i}`));
      const rows = instance.eventsSince("s1", 1);
      // 1 番から欲しいと言ったのに、持っている最古はそれより後。
      expect(rows.oldestSeq).toBeGreaterThan(1);
    });
  });

  it("rejects a malformed event instead of storing it", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:bad-test"));
    await runInDurableObject(stub, async (instance) => {
      // sessionId が無い。保存されれば電話に配り返すことになる。
      const bad = { type: "event", eventId: "x", kind: "assistant", text: "hi", at: 0 } as never;
      expect(instance.appendEvent(bad)).toBeNull();
      expect(instance.eventsSince("", 0).events.length).toBe(0);
    });
  });

  it("evicts the least recently written session past the session cap", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:sessions-test"));
    await runInDurableObject(stub, async (instance) => {
      for (let i = 0; i < 21; i++) instance.appendEvent(ev(`s${i}`, "x"));
      // 最初に書いたセッションが丸ごと消えている。
      expect(instance.eventsSince("s0", 0).events.length).toBe(0);
      expect(instance.eventsSince("s20", 0).events.length).toBe(1);
    });
  });

  it("caps a single event's text", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:size-test"));
    await runInDurableObject(stub, async (instance) => {
      const huge = { ...ev("s1", "x"), text: "a".repeat(50_000) };
      instance.appendEvent(huge);
      const stored = instance.eventsSince("s1", 0).events[0];
      expect(stored.text.length).toBeLessThanOrEqual(8 * 1024);
    });
  });
});
```

- [ ] **Step 2: 走らせて落ちることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile/worker
npx tsc --noEmit
npm test
```

Expected: `appendEvent is not a function` 相当で失敗。

- [ ] **Step 3: types.ts に形を足す**

```ts
/** Canopy が publisher ソケットに流す 1 件の出来事。
 *
 *  `type` を持つことが roster のスナップショットとの唯一の違いであり、
 *  `webSocketMessage` はこのフィールドだけで両者を分ける。スナップショット
 *  は `type` を持たない。 */
export interface SessionEventMessage {
  type: "event";
  eventId: string;
  sessionId: string;
  resumeId: string | null;
  kind: "assistant" | "user" | "tool" | "turnStart" | "turnEnd";
  text: string;
  at: number;
}

/** watcher に配る形。`seq` は DO が振る。 */
export interface StoredSessionEvent extends SessionEventMessage {
  seq: number;
}

/** バックフィルの応答。`oldestSeq` は「いま持っている最古」であり、
 *  要求値より大きければ電話はそこに穴があると判定できる。 */
export interface EventsResponse {
  type: "events";
  sessionId: string;
  oldestSeq: number;
  events: StoredSessionEvent[];
}
```

- [ ] **Step 4: machine.ts にテーブルと取り込みを足す**

コンストラクタの `blockConcurrencyWhile` 内、既存の `snapshot` テーブル作成の直後：

```ts
      this.ctx.storage.sql.exec(
        `CREATE TABLE IF NOT EXISTS event (
           seq        INTEGER PRIMARY KEY AUTOINCREMENT,
           session_id TEXT NOT NULL,
           event_id   TEXT NOT NULL,
           resume_id  TEXT,
           kind       TEXT NOT NULL,
           text       TEXT NOT NULL,
           created_at INTEGER NOT NULL
         )`
      );
      this.ctx.storage.sql.exec(
        `CREATE INDEX IF NOT EXISTS event_by_session ON event (session_id, seq)`
      );
```

クラス本体に：

```ts
  /** 1 セッションが保持するイベント数の上限。spec の「直近だけ遡れればいい」の具体化。 */
  static readonly maxEventsPerSession = 200;
  /** 保持するセッション数の上限。最終書き込みが古い順に丸ごと捨てる。 */
  static readonly maxSessions = 20;
  /** 1 イベントのテキスト上限（文字数）。Canopy 側もバイトで切っているが、
   *  ここは relay に入る値の最後の砦であり、Canopy を信用しない。 */
  static readonly maxEventTextLength = 8 * 1024;

  /** イベントを 1 件保存し、振った seq を返す。拒否したときは null。
   *
   *  **形の検査は保存の前に行う。** 壊れた値を保存すると、あとで電話に
   *  そのまま配り返すことになる。スナップショット側で同じ間違いが watch
   *  ソケットを恒久的に殺した前例がある。 */
  appendEvent(msg: SessionEventMessage): number | null {
    if (
      typeof msg?.sessionId !== "string" || msg.sessionId.length === 0 ||
      typeof msg.eventId !== "string" || msg.eventId.length === 0 ||
      typeof msg.kind !== "string" || typeof msg.text !== "string"
    ) {
      console.error("rejected event: malformed shape");
      return null;
    }
    const text = msg.text.slice(0, MachineDO.maxEventTextLength);
    // **`Date.now()` を代替にしない。** Canopy は Swift の `JSONEncoder` 既定
    // で送るので、この数は 2001 年起点の秒である。エポックのミリ秒を混ぜると
    // 電話側の `Date` decode が数万年先の日付になり、合成した会話の並びが
    // 壊れる。時刻が無いのは 0 として扱い、並びの先頭に落とすほうが安全。
    const at = typeof msg.at === "number" ? msg.at : 0;
    const rows = this.ctx.storage.sql
      .exec<{ seq: number }>(
        `INSERT INTO event (session_id, event_id, resume_id, kind, text, created_at)
         VALUES (?, ?, ?, ?, ?, ?) RETURNING seq`,
        msg.sessionId, msg.eventId, msg.resumeId ?? null, msg.kind, text, at
      )
      .toArray();
    const seq = rows[0]?.seq ?? null;
    if (seq === null) return null;
    this.trim(msg.sessionId);
    return seq;
  }

  /** 上限を超えたぶんを捨てる。書き込みのたびに走る。 */
  private trim(sessionId: string): void {
    this.ctx.storage.sql.exec(
      `DELETE FROM event WHERE session_id = ? AND seq NOT IN (
         SELECT seq FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT ?
       )`,
      sessionId, sessionId, MachineDO.maxEventsPerSession
    );
    this.ctx.storage.sql.exec(
      `DELETE FROM event WHERE session_id NOT IN (
         SELECT session_id FROM event GROUP BY session_id ORDER BY MAX(seq) DESC LIMIT ?
       )`,
      MachineDO.maxSessions
    );
  }

  /** `after` より後のイベントと、いま持っている最古の seq を返す。
   *
   *  **`oldestSeq` を必ず返すのが要である。** 黙って部分列を返すと、電話は
   *  それを連続だと思って繋いでしまう。要求値より `oldestSeq` が大きければ
   *  そこに穴がある。 */
  eventsSince(sessionId: string, after: number): EventsResponse {
    const events = this.ctx.storage.sql
      .exec<StoredSessionEvent & { session_id: string; event_id: string; resume_id: string | null; created_at: number }>(
        `SELECT seq, session_id, event_id, resume_id, kind, text, created_at
           FROM event WHERE session_id = ? AND seq > ? ORDER BY seq ASC`,
        sessionId, after
      )
      .toArray()
      .map((r) => ({
        type: "event" as const,
        seq: r.seq,
        eventId: r.event_id,
        sessionId: r.session_id,
        resumeId: r.resume_id,
        kind: r.kind,
        text: r.text,
        at: r.created_at,
      }));
    const oldest = this.ctx.storage.sql
      .exec<{ seq: number }>(`SELECT MIN(seq) AS seq FROM event WHERE session_id = ?`, sessionId)
      .toArray();
    return {
      type: "events",
      sessionId,
      oldestSeq: oldest[0]?.seq ?? 0,
      events,
    };
  }
```

`webSocketMessage` の、ack を見たあと・スナップショットの形の検査の**前**に：

```ts
    if (parsed.type === "event") {
      const seq = this.appendEvent(parsed as unknown as SessionEventMessage);
      if (seq === null) return;
      this.broadcastEvent({ ...(parsed as unknown as SessionEventMessage), seq });
      return;
    }
```

そして配信：

```ts
  /** 1 件のイベントを watcher 全員に配る。publisher は飛ばす。 */
  private broadcastEvent(event: StoredSessionEvent): void {
    const text = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      if (attachment?.role !== "watcher") continue;
      try {
        ws.send(text);
      } catch {
        // 去った watcher は routine。次のイベントで作り直される。
      }
    }
  }
```

- [ ] **Step 5: 型検査とテストを両方走らせる**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile/worker
npx tsc --noEmit
npm test
```

Expected: tsc が無言で終わり、テストが全部通る。

- [ ] **Step 6: 変異テストで実効性を確認する**

`trim()` の 1 本目の `DELETE`（セッション内トリム）をコメントアウトして `npm test`。`keeps the newest events…` が落ちること。戻して緑を確認する。

- [ ] **Step 7: commit**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
git add worker/src/types.ts worker/src/machine.ts worker/src/machine.test.ts
git commit -m "Store session events in a per-session ring buffer"
```

---

## Task 4: バックフィルの往復

**Files:**
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/worker/src/machine.ts`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/worker/src/machine.test.ts`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `MachineDO.eventsSince(sessionId, after)`（Task 3）
- Produces: watcher が送れる要求 `{type:"events_since", sessionId, seq}`、DO が返す `EventsResponse`

- [ ] **Step 1: 失敗するテストを書く**

```ts
  it("answers a watcher's events_since over its own socket", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:backfill-test"));
    await runInDurableObject(stub, async (instance) => {
      instance.appendEvent(ev("s1", "one"));
      instance.appendEvent(ev("s1", "two"));
      const replies: string[] = [];
      const fake = { send: (t: string) => replies.push(t), deserializeAttachment: () => ({ role: "watcher" }) };
      instance.webSocketMessage(
        fake as unknown as WebSocket,
        JSON.stringify({ type: "events_since", sessionId: "s1", seq: 0 })
      );
      expect(replies.length).toBe(1);
      const body = JSON.parse(replies[0]);
      expect(body.type).toBe("events");
      expect(body.events.length).toBe(2);
      expect(typeof body.oldestSeq).toBe("number");
    });
  });

  it("ignores an events_since with no sessionId", async () => {
    const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:backfill-bad"));
    await runInDurableObject(stub, async (instance) => {
      const replies: string[] = [];
      const fake = { send: (t: string) => replies.push(t), deserializeAttachment: () => ({ role: "watcher" }) };
      instance.webSocketMessage(fake as unknown as WebSocket, JSON.stringify({ type: "events_since", seq: 0 }));
      expect(replies.length).toBe(0);
    });
  });
```

- [ ] **Step 2: 走らせて落ちることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile/worker
npm test
```

Expected: `replies.length` が 0 で失敗。

- [ ] **Step 3: webSocketMessage に分岐を足す**

`event` の分岐の直後に：

```ts
    if (parsed.type === "events_since") {
      const sessionId = (parsed as { sessionId?: unknown }).sessionId;
      if (typeof sessionId !== "string" || sessionId.length === 0) return;
      const after = typeof (parsed as { seq?: unknown }).seq === "number"
        ? (parsed as { seq: number }).seq
        : 0;
      try {
        ws.send(JSON.stringify(this.eventsSince(sessionId, after)));
      } catch {
        // 去った watcher。次の接続でやり直す。
      }
      return;
    }
```

- [ ] **Step 4: 型検査とテストを走らせる**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile/worker
npx tsc --noEmit
npm test
```

Expected: 全部通る。

- [ ] **Step 5: floor を測って上げる**

`npm test` の出力の `Tests  N passed` の **N を** `.github/workflows/ci.yml` の `EXPECTED_TESTS` に書く。計算しない。

- [ ] **Step 6: commit**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
git add worker/src/machine.ts worker/src/machine.test.ts .github/workflows/ci.yml
git commit -m "Answer a watcher's backfill request with the seq it can resume from"
```

---

## Task 5: 電話側の受信（ストアとソケット）

**Files:**
- Create: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/SessionEventStore.swift`
- Create: `/Users/hiko/repos/Personal/Canopy-Mobile/Tests/SessionEventTests.swift`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/RosterSocket.swift`

**Interfaces:**
- Consumes: DO が配る `{type:"event", seq, …}` と `{type:"events", oldestSeq, events:[…]}`（Task 3, 4）
- Produces:
  - `struct SessionEventRecord: Codable, Identifiable, Hashable, Sendable`（`id` は `eventId`）
  - `@Observable @MainActor final class SessionEventStore` — `func apply(_ record: SessionEventRecord)`, `func apply(backfill: [SessionEventRecord], oldestSeq: Int)`, `func events(sessionId: String, resumeId: String?) -> [SessionEventRecord]`, `var lastSeq: Int`, `func hasGap(before: Int) -> Bool`
  - `RosterSocket.connect(machine:onSnapshot:onEvent:onFailure:)`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/SessionEventTests.swift`:

```swift
import Testing
@testable import CanopyMobile

@MainActor
struct SessionEventStoreTests {
    private func rec(_ seq: Int, _ session: String = "s1", _ text: String = "x") -> SessionEventRecord {
        SessionEventRecord(seq: seq, eventId: "e\(seq)", sessionId: session,
                           resumeId: nil, kind: .assistant, text: text,
                           at: Date(timeIntervalSince1970: Double(seq)))
    }

    @Test func ordersBySeqRegardlessOfArrival() {
        let store = SessionEventStore()
        store.apply(rec(3))
        store.apply(rec(1))
        store.apply(rec(2))
        #expect(store.events(sessionId: "s1", resumeId: nil).map(\.seq) == [1, 2, 3])
    }

    @Test func dropsARepeatedSeq() {
        let store = SessionEventStore()
        store.apply(rec(1, "s1", "first"))
        store.apply(rec(1, "s1", "second"))
        let all = store.events(sessionId: "s1", resumeId: nil)
        #expect(all.count == 1)
        #expect(all[0].text == "first")
    }

    @Test func tracksTheHighestSeqSeen() {
        let store = SessionEventStore()
        store.apply(rec(5))
        store.apply(rec(2))
        #expect(store.lastSeq == 5)
    }

    @Test func separatesSessions() {
        let store = SessionEventStore()
        store.apply(rec(1, "s1"))
        store.apply(rec(2, "s2"))
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 1)
        #expect(store.events(sessionId: "s2", resumeId: nil).count == 1)
    }

    @Test func reportsAGapWhenTheBackfillStartsLaterThanAsked() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(10), rec(11)], oldestSeq: 10)
        // 0 から欲しかったのに 10 からしか無い。
        #expect(store.hasGap(before: 10))
    }

    @Test func reportsNoGapWhenTheBackfillIsComplete() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1)
        #expect(!store.hasGap(before: 1))
    }
}
```

- [ ] **Step 2: 走らせて落ちることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS Simulator,id=EA5B4E30-9D77-49D9-9D7E-C6D86CFE796E' 2>&1 | tail -20
```

Expected: `cannot find 'SessionEventStore' in scope`。

- [ ] **Step 3: SessionEventStore.swift を書く**

```swift
import Foundation
import Observation

/// DO から届いた 1 件の出来事。
///
/// `id` は `eventId` — **`seq` ではない**。`seq` は DO の採番で、順序と
/// 再開に使う。`eventId` は Canopy が振り、completed push にも載るので、
/// 通知履歴との重複排除に使える唯一の鍵である。
struct SessionEventRecord: Codable, Identifiable, Hashable, Sendable {
    let seq: Int
    let eventId: String
    let sessionId: String
    let resumeId: String?
    let kind: Kind
    let text: String
    let at: Date

    var id: String { eventId }

    enum Kind: String, Codable, Sendable {
        case assistant, user, tool, turnStart, turnEnd
    }
}

/// 受信したイベントを保持する。**恒久ストアではない** — アプリの寿命だけ
/// 生き、通知履歴（`HistoryStore`）とは別物である。通知履歴は端末に残り
/// オフラインでも読めるが、こちらは直近 N 件のライブ表示にすぎない。
/// 片方でもう片方を置き換えないこと。
@Observable
@MainActor
final class SessionEventStore {
    /// seq をキーにするので、同じイベントが二度届いても増えない。
    /// 再接続直後のバックフィルとライブ配信は重なりうる。
    private var bySeq: [Int: SessionEventRecord] = [:]
    /// バックフィル応答が返した「DO が持っている最古」。穴の判定に使う。
    private var oldestHeld: Int?

    /// これまでに見た最大の seq。再開要求 `events_since` に載せる。
    private(set) var lastSeq: Int = 0

    func apply(_ record: SessionEventRecord) {
        // 先勝ち。同じ seq の 2 通目は DO の再送であって新しい事実ではない。
        if bySeq[record.seq] == nil { bySeq[record.seq] = record }
        lastSeq = max(lastSeq, record.seq)
    }

    func apply(backfill: [SessionEventRecord], oldestSeq: Int) {
        oldestHeld = oldestSeq
        for record in backfill { apply(record) }
    }

    /// 要求した seq より DO の最古が新しければ、その間は永久に読めない。
    /// **これを黙って繋ぐと、電話は連続した会話だと誤解する。**
    func hasGap(before requested: Int) -> Bool {
        guard let oldestHeld, oldestHeld > 0 else { return false }
        return oldestHeld > requested
    }

    /// 1 セッション分を時刻順で返す。`resumeId` が両側にあればそれで照合する
    /// — `sessionId` は Canopy のプロセスごとに作られるので、Mac を再起動
    /// すると過去のイベントと結びつかなくなる（通知履歴と同じ理由）。
    func events(sessionId: String, resumeId: String?) -> [SessionEventRecord] {
        bySeq.values
            .filter { record in
                if let resumeId, let theirs = record.resumeId { return theirs == resumeId }
                return record.sessionId == sessionId
            }
            .sorted { $0.seq < $1.seq }
    }
}
```

- [ ] **Step 4: RosterSocket にイベントの経路を足す**

`connect` の引数に `onEvent: @escaping @Sendable (SessionEventRecord) -> Void` と
`onBackfill: @escaping @Sendable ([SessionEventRecord], Int) -> Void` を加え、
`receive` の decode をこう置き換える。

```swift
                var snapshot: MachineSnapshot?
                if case .string(let text) = message,
                   let data = text.data(using: .utf8) {
                    let decoder = JSONDecoder()
                    // **`type` の有無で分ける。** roster のスナップショットは
                    // `type` を持たないので、これが唯一の判別材料である。
                    // 先に snapshot として試すと、event が「panes が無い
                    // スナップショット」として黙って捨てられる。
                    let tag = (try? decoder.decode(TypeTag.self, from: data))?.type
                    switch tag {
                    case "event":
                        if let record = try? decoder.decode(SessionEventRecord.self, from: data) {
                            Task { @MainActor in onEvent(record) }
                        }
                    case "events":
                        if let page = try? decoder.decode(EventsPage.self, from: data) {
                            Task { @MainActor in onBackfill(page.events, page.oldestSeq) }
                        }
                    default:
                        snapshot = try? decoder.decode(MachineSnapshot.self, from: data)
                    }
                }
```

同ファイル末尾に：

```swift
/// `type` だけを読むための最小の形。判別してから本体を decode する。
private struct TypeTag: Decodable { let type: String? }

/// バックフィルの応答。`oldestSeq` は DO が持っている最古の seq。
private struct EventsPage: Decodable {
    let oldestSeq: Int
    let events: [SessionEventRecord]
}
```

そして再開要求を送る口を足す。

```swift
    /// 「この seq より後を全部くれ」と頼む。接続直後と、セッションを開いた
    /// ときに呼ぶ。応答は `onBackfill` に来る。
    func requestEvents(sessionId: String, since seq: Int) {
        let body: [String: Any] = ["type": "events_since", "sessionId": sessionId, "seq": seq]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }
```

**日付の扱いを合わせること。** Canopy 側は `JSONEncoder` の既定で `Double` を書き、DO は `at` を数値のまま通す。`SessionEventRecord` の `at` を `Date` として decode するには、`JSONDecoder` の `dateDecodingStrategy` を既定（`.deferredToDate`）のままにする。**両側の戦略が揃っていることを Step 5 の実機確認で見る** — ずれると日付だけが静かに 1970 年になる。

- [ ] **Step 5: テストとビルドを走らせる**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS Simulator,id=EA5B4E30-9D77-49D9-9D7E-C6D86CFE796E' 2>&1 | tail -20
```

Expected: 全部通る。

- [ ] **Step 6: floor を測って上げる**

テスト出力の通過数を読み、その数を `.github/workflows/ci.yml` の `EXPECTED_SWIFT_TESTS` に書く。計算しない。

- [ ] **Step 7: commit**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
git add Sources/SessionEventStore.swift Sources/RosterSocket.swift Tests/SessionEventTests.swift .github/workflows/ci.yml
git commit -m "Receive session events on the watch socket"
```

---

## Task 6: 会話画面での合成と重複排除

**Files:**
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/Shared/NotificationHistoryItem.swift`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/CanopyMobileNotificationService/NotificationService.swift`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/CanopyMobileApp.swift`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Sources/SessionConversationView.swift`
- Modify: `/Users/hiko/repos/Personal/Canopy-Mobile/Tests/SessionEventTests.swift`

**Interfaces:**
- Consumes: `SessionEventStore`, `SessionEventRecord`（Task 5）、`NotificationHistoryItem`
- Produces:
  - `NotificationHistoryItem.eventId: String?`
  - `enum ConversationRow: Identifiable`（`.item(NotificationHistoryItem)` / `.event(SessionEventRecord)`）
  - `static func ConversationRow.merge(items: [NotificationHistoryItem], events: [SessionEventRecord]) -> [ConversationRow]`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/SessionEventTests.swift` に追記：

```swift
@MainActor
struct ConversationMergeTests {
    private func item(_ id: String, _ t: TimeInterval, eventId: String? = nil,
                      kind: String = "completed") -> NotificationHistoryItem {
        NotificationHistoryItem(id: id, receivedAt: Date(timeIntervalSince1970: t),
                                title: "Canopy", body: "b", bodyShort: nil,
                                machine: "M", sessionId: "s1", kind: kind,
                                requestId: nil, eventId: eventId)
    }
    private func event(_ seq: Int, _ t: TimeInterval, eventId: String) -> SessionEventRecord {
        SessionEventRecord(seq: seq, eventId: eventId, sessionId: "s1", resumeId: nil,
                           kind: .assistant, text: "e", at: Date(timeIntervalSince1970: t))
    }

    @Test func ordersBothSourcesByTime() {
        let rows = ConversationRow.merge(items: [item("i1", 30)], events: [event(1, 10, eventId: "e1")])
        #expect(rows.count == 2)
        if case .event = rows[0] {} else { Issue.record("the older event should come first") }
    }

    @Test func dropsANotificationThatDuplicatesAnEvent() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "e1")],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 1)
        if case .item = rows[0] { Issue.record("the notification duplicate should be dropped") }
    }

    @Test func keepsAnAskingNotificationEvenWithEvents() {
        // asking は答えられる唯一の経路。イベント列に代替がないので必ず残す。
        let rows = ConversationRow.merge(items: [item("i1", 30, kind: "asking")],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 2)
    }

    @Test func keepsANotificationWithNoEventId() {
        // 古いビルドが書いた記録には eventId が無い。落としてはいけない。
        let rows = ConversationRow.merge(items: [item("i1", 30)],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 2)
    }
}
```

- [ ] **Step 2: 走らせて落ちることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS Simulator,id=EA5B4E30-9D77-49D9-9D7E-C6D86CFE796E' 2>&1 | tail -20
```

Expected: `cannot find 'ConversationRow' in scope`。

- [ ] **Step 3: NotificationHistoryItem に eventId を足す**

`resumeId` の隣に：

```swift
    /// Canopy が同じ内容のイベントに振った id。**この push とイベントが
    /// 同じものだと言える唯一の鍵である** — 履歴の `id` は NSE がローカルで
    /// 作る UUID なので Canopy 側とは一致しない。古いビルドが書いた記録には
    /// 無いので `nil` を「重複ではない」と読むこと。
    var eventId: String?
```

**この型には明示的な `init` がある**（`Sources/Shared/NotificationHistoryItem.swift:214`）。プロパティを足すだけでは足りない — 同じ init の引数リスト末尾に `eventId: String? = nil` を加え、本体に `self.eventId = eventId` を書く。既定値を付けるので既存の呼び出しは変わらない。

- [ ] **Step 4: NSE で取り込む**

`NotificationService.swift` の `historyId` を作っている付近で：

```swift
        let eventId = userInfo["eventId"] as? String
```

そして `NotificationHistoryItem(...)` の生成に `eventId: eventId` を渡す。

- [ ] **Step 5: ConversationRow を書く**

`Sources/SessionConversationView.swift` の先頭付近（`SessionConversationView` の外）に：

```swift
/// 会話画面の 1 行。通知履歴とライブイベントの合成結果。
enum ConversationRow: Identifiable {
    case item(NotificationHistoryItem)
    case event(SessionEventRecord)

    var id: String {
        switch self {
        case .item(let i): return "i-\(i.id)"
        case .event(let e): return "e-\(e.eventId)"
        }
    }

    var at: Date {
        switch self {
        case .item(let i): return i.receivedAt
        case .event(let e): return e.at
        }
    }

    /// 2 つの源を時刻順に並べ、重複を落とす。
    ///
    /// **落とすのは `completed` の通知だけである。** `asking` は Allow/Deny
    /// や選択肢に答えられる唯一の経路で、イベント列に代替がない。イベントに
    /// 同じ内容が流れていても残す。
    ///
    /// `eventId` を持たない通知（このフィールドより前のビルドが書いた記録）は
    /// 重複だと判定できないので残す。**`nil` を「重複」と読むと履歴が消える。**
    static func merge(items: [NotificationHistoryItem],
                      events: [SessionEventRecord]) -> [ConversationRow] {
        let seen = Set(events.map(\.eventId))
        let kept = items.filter { item in
            guard item.kind == "completed", let eventId = item.eventId else { return true }
            return !seen.contains(eventId)
        }
        return (kept.map(ConversationRow.item) + events.map(ConversationRow.event))
            .sorted { $0.at < $1.at }
    }
}
```

- [ ] **Step 6: 画面を合成結果で描く**

`SessionConversationView` に `@Environment` か `@Bindable` で `SessionEventStore` を受け取り、`ForEach(Array(items.enumerated()), id: \.element.id)` を次に置き換える。

```swift
                        let rows = ConversationRow.merge(
                            items: items,
                            events: eventStore.events(sessionId: sessionId, resumeId: resumeId)
                        )
                        ForEach(rows) { row in
                            switch row {
                            case .item(let item):
                                MessageBlock(item: item, onDecision: onDecision, onAnswer: onAnswer)
                            case .event(let event):
                                SessionEventBlock(event: event)
                            }
                        }
```

`SessionEventBlock` は同ファイル内に足す。**ダークモードは実装しない** — 単一パレット。

```swift
/// ライブイベント 1 件。`tool` は細い 1 行、それ以外は本文として描く。
private struct SessionEventBlock: View {
    let event: SessionEventRecord

    var body: some View {
        switch event.kind {
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(event.text)
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .turnStart, .turnEnd:
            // 境界は行として描かない。会話の流れを切るだけで情報がない。
            EmptyView()
        case .assistant, .user:
            Text(event.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
```

- [ ] **Step 7: アプリに store を持たせ、接続時に再開要求を出す**

`CanopyMobileApp.swift` に `@State private var eventStore = SessionEventStore()` を足し、`RosterSocket.connect` の呼び出しに `onEvent: { eventStore.apply($0) }` と
`onBackfill: { eventStore.apply(backfill: $0, oldestSeq: $1) }` を渡す。
`SessionConversationView` を開くときに `socket.requestEvents(sessionId: sessionId, since: eventStore.lastSeq)` を呼ぶ。

- [ ] **Step 8: テストとビルドを走らせる**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
xcodebuild test -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS Simulator,id=EA5B4E30-9D77-49D9-9D7E-C6D86CFE796E' 2>&1 | tail -20
```

Expected: 全部通る。

- [ ] **Step 9: 変異テストで実効性を確認する**

`merge` の `guard item.kind == "completed", let eventId = item.eventId else { return true }` を
`guard let eventId = item.eventId else { return true }` に変える（`asking` も落とすようにする）。
`keepsAnAskingNotificationEvenWithEvents` が落ちること。戻して緑を確認する。

- [ ] **Step 10: floor を測って上げる**

テスト出力の通過数を読み、その数を `EXPECTED_SWIFT_TESTS` に書く。計算しない。

- [ ] **Step 11: commit**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
git add Sources/Shared/NotificationHistoryItem.swift \
        Sources/CanopyMobileNotificationService/NotificationService.swift \
        Sources/CanopyMobileApp.swift Sources/SessionConversationView.swift \
        Sources/RosterSocket.swift Tests/SessionEventTests.swift .github/workflows/ci.yml
git commit -m "Merge live session events into the conversation view"
```

---

## Task 7: 実機での通し確認

**Files:** なし（測定のみ。結果は spec に追記する）

**Interfaces:**
- Consumes: Task 1〜6 のすべて
- Produces: spec への「実測」節の追記

- [ ] **Step 1: relay をデプロイする**

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile/worker
npx wrangler deploy
```

- [ ] **Step 2: Canopy の Debug ビルドを起動し、iPhone に新ビルドを入れる**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```

```bash
cd /Users/hiko/repos/Personal/Canopy-Mobile
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile -configuration Release \
  -destination 'id=88CF0177-6AA8-5D02-926C-27E21B989A53' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device 88CF0177-6AA8-5D02-926C-27E21B989A53 \
  build/Build/Products/Release-iphoneos/CanopyMobile.app
```

`find` で `.app` を拾うときは **`-path '*iphoneos*'` を必ず付ける** — シミュレータ用の古いビルドを掴むと、署名が通らずインストールに失敗する。

- [ ] **Step 3: 4 つを目で確認する**

1. 電話でセッションを開き、Mac 側で 1 turn 走らせる。アシスタントの発言が**完成した時点で**現れること。
   **Mac で打ったプロンプト自身も `user` イベントとして電話に出ること。** これは推論であって実測ではない — CLI 単体の出力に `user` フレームは無く、エコーを作っているのは拡張のほうだと読んでいる（`isKeepAliveEcho` と `isRecapEcho` が、注入したプロンプトが `user` の io_message として返ることを前提に組まれている）。**出なかった場合、Task 1 の `user` ケースは死にコードである** — そのときは拡張が何を送っているかを `[stdout→webview] type=` のログで数え、直してから先に進むこと。
2. ツールを使う turn で、ツール名の細い行が出て、**コマンドやパスが出ていない**こと。
3. 完了 push が届いたとき、**同じ文章が 2 つ並ばない**こと。
4. アプリを閉じて数 turn 進め、開き直したときに直近が読めること。

- [ ] **Step 4: 実測を spec に書き足す**

`docs/superpowers/specs/2026-09-06-canopy-mobile-event-stream-design.md` に「実測」節を足し、上の 4 点の結果と、1 turn あたりのイベント件数を書く。**推定ではなく数えた数を書く。**

- [ ] **Step 5: commit**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/mobile-event-stream
git add docs/superpowers/specs/2026-09-06-canopy-mobile-event-stream-design.md
git commit -m "Record the on-device measurements for the event stream"
```
