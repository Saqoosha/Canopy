# 他の Mac の live セッションをサイドバーに出し、クリックで attach する

2026-09-15。設計。実装はまだ。前提の実測は [2026-09-14-multi-client-mirror-spike.md](2026-09-14-multi-client-mirror-spike.md) にある。

## 目標

1. サイドバーに、他の Mac で開いているセッションが machine ごとに並ぶ。dot は local 行と同じ `ActivityDot`
2. その行をクリックすると、その Mac の `MirrorServer` に attach してペインに載る。tmux の attach と同じ形
3. roster が pane だけでなく **open セッション全部**（pane あり + pane なし）を運ぶ。phone もそれを描く

閉じた Recents（履歴）は運ばない。roster の「今の状態だけ、会話の中身は運ばない」契約とサイズが変わるので、別の話として切った。

## 今あるもの

- **relay がもう全 Mac の live 一覧を持っている。** `GET /machines` が machine id の配列、`GET /watch?machine=<id>` の WebSocket が snapshot を push する（接続直後に最新の 1 枚、以後は変化ごと）。phone はこれを読んでいるだけ。Canopy は同じ shared secret を Keychain（`sh.saqoo.Canopy.roster`）に持っていて、`RosterPublisher.sharedSecret()` で読める
- **attach は `host:port` + password。** `MirrorServer` は最初の行 `{"type":"attach","sessionId","token"}` を定数時間比較で検証し、`store.openSessions` の中で `resumeId` が一致して **shim を持つ** セッションにだけ繋ぐ。shim が無ければ `attach_error: no such session`
- **phone は `canopy-mirror://<ip>:<port>?token=…&machine=<id>` を貼って machine ごとに保存する**（`MirrorConnectionStore`）。Mac 側の生成は `MirrorAccess.connectionString`、Settings › Mobile の「Copy Connection for iPhone」
- **Mac 側の attach client は DEBUG の別窓だけ。** `MirrorAttachWindow` + `RemoteMirrorBridge`（`#if DEBUG`）。WKWebView を pane と同じ user script で立て、`vscodeHost` handler を TCP に流している。ペインには載っていない
- roster の行は `RosterSnapshot.Pane`。`snapshot()` は `paneIndexes(in: store.panes)` に無い open セッションを `continue` で落としている。Worker は `panes` が配列であることしか見ない。phone の `PaneRow` は `paneIndex: Int` 必須、並び順は Mac が sort した順のまま

## 決めたこと

### 1. リモート一覧の出どころは relay

Canopy が phone と同じ **watcher** になる。自分の `MachineIdentity.stableId()` は除く。relay のコード変更はゼロ。

代案は各 Mac の `MirrorServer` に `list` verb を足して直接聞く形。relay が無くても Tailscale だけで閉じる利点があるが、N 台の polling、2 本目のプロトコル、roster と同じデータの二重持ちになる。落とす。

状態も relay から来る。`RosterSnapshot.wireState(for:)` の逆写像を同じ場所に置き（`activity(fromWireState:)`、往復を probe で固定）、`ActivityDot` にそのまま流す。dot と phone の色が一致するのは、両方が同じ wire state を読むから。

### 2. サイドバーの行

`SidebarRow` に `.remoteLive(RemoteLiveSession)` を足す。`RemoteLiveSession` は値型：`machineId`、`machineName`、`row: RosterSnapshot.Pane`、`stale: Bool`。id は `remote:<machineId>:<sessionId>`。

- **置き場所は Open の下、Recents の上**、machine ごとの `Section`（title は `displayName`）。live なものは履歴より上
- `isOpen` は false。pane strip の地図（Open ブロック）には入れない
- `visibleRows` のパイプラインを通さず、launcher 行と同じく **後から Sidebar で組む**。`sorted` / `deduped` / `filter.apply` / `SidebarGrouping` を触らない。filter gear はこの Mac の履歴に対する意図なので、リモート行には効かせない（受け入れた制限）
- **すでに attach 済みのセッションの行は隠す。** `.mirror` origin の `OpenSession` と `(machineId, sessionId)` が一致する行は落とす。teleport 済み cloud 行を `deduped` が落とすのと同じ理由。Open ブロックにその pane の行がある
- `live == false` の行（後述）は `canOpen` false。クリックできず、tooltip に「Not running on <machine>」。`SidebarRow.canOpen` は exhaustive switch なので新 case が判断を強制する
- `stale`（`publishedAt` が古い、閾値は phone の `isStale` と同じ値）は 0.5 opacity + dot は idle。phone と同じ表現
- rename 不可、Hide 不可。context menu は「Copy Session ID」だけ
- plain click → `openInFocusedPane`、Cmd+click → `openInNewPane`。cloud 行と同じ

### 3. watcher

`Sources/Canopy/Roster/RemoteRosterWatcher.swift`。`@Observable @MainActor`、`SessionStore` は `remoteRosters: [machineId: RosterSnapshot]` と `remoteMachineNames` を読むだけで、所有は watcher。

- `settings.rosterEnabled` と secret の両方が揃ったら動く。`RosterPublisher` と同じ tracked closure で toggle に追随する
- 起動時と 5 分ごとに `GET /machines`。自分を除いた各 id に `/watch` socket を 1 本。id が消えたら socket を閉じる
- socket は `RosterSocket`（phone）と同じ decode：`type` を peek して、無ければ snapshot、あれば event / ack で **捨てる**。`RosterSnapshot` は Codable なのでそのまま decode できる
- 切断は `RosterReconnectFloor` と同じ床で再接続。30 秒 ping は publisher と同じ理由で要る（半開きは何も報告しない、2026-09-05 実測）
- `CANOPY_RUN_LOGIC_PROBE=1` では起動しない。`startRosterPublisher` と同じ穴（`.task` は probe の exit より先に走る）
- 窓が隠れていても止めない。watcher socket は relay 側で hibernation の対象で課金されず、この側は何もしない。cloud polling が sidebar 非表示で止まるのは API 呼び出しの節約で、ここには当てはまらない

### 4. attach してペインに載せる

ここが一番大きい。

**`OpenSession.Origin.mirror(machineId: String, host: String, port: UInt16)`** を足す。`resumeId` は remote の session id。`title` / `project` は roster の行から。

- `workingDirectory` は `.mirror` で home dir を返す。今 `MirrorAttachWindow` が `LinkClickHandler` に渡しているのと同じ。到達する消費者は `LinkClickHandler` の path 封じ込めだけで、home 外は全部拒否になる（remote のファイルは開けないので正しい）。`PaneHeaderMenu` と `Sidebar` の「remoteHost == nil なら Finder で開く」は `.mirror` も除外する。`Origin.localWorkingDirectory: URL?` を足して、その 2 箇所はそれを読む
- `projectLabel` は `.remote` と同じく `project` をそのまま返す
- `remoteHost` は nil のまま。SSH remote の再接続経路（`ShimProcess`）を踏ませない。status bar の machine 名は別 field で出す

**`SessionContainer` が origin で分岐する。** `.mirror` なら `WebViewContainer` の代わりに `MirrorPaneView`（新規 `NSViewRepresentable`）。

- WKWebView は `WebViewContainer.buildWebView` と同じ材料で立てる：`addSessionUserScripts`、`consoleLog`、`canopyLink`、`canopyInputWidth`、`allowFileAccessFromFileURLs`。`vscodeHost` には `RemoteMirrorBridge`
- webView は `OpenSession.webView` に、bridge は新しい `OpenSession.mirrorBridge` に保持する。shim と同じく **OpenSession が canonical owner**。pane swap は `WebViewContainer` と同じ in-place subview swap で、`SessionWebViewHost.expectedWebView` の再採用ルールも同じ
- `RemoteMirrorBridge` は `#if DEBUG` の外に出して `MirrorClient.swift` に移す。`MirrorAttachWindow` はそれを使い続ける。追加：token を引数で受ける、`attach_ok` で `onAttached`、`attach_error` で `onRefused(reason)`、socket の `failed` / EOF で `onDropped`
- 順序は既存どおり：socket `ready` → `attach` 送信 → その後で `loadCCWebview`。webview の `init` が `attach` より先に socket へ出ない
- `status` は `.spawning` で作り、`attach_ok` で `.live`。`SpawningOverlay` の文言は「Attaching to <machine>…」
- `attach_error` → `SessionStore.noteSessionFailure` に理由を渡してペインを閉じる。shim crash と同じ経路で、`DetailLauncher` の banner に出る。理由の対応：`unauthorized` → 「<machine> rejected the password. Paste its connection again in Settings › Mobile」、`no such session` → 「That session is no longer running on <machine>」
- 接続断 → `session.connection`（`ConnectionState`）を `.reconnecting` にして `ConnectionOverlayView` を出す。Retry は bridge を作り直して attach し直し、`loadCCWebview` をやり直す（server が `get_session_request` の replay で transcript を丸ごと返すので、webview は reload で復元される）。自動再接続は v1 では無し。SSH の 3 回 backoff は shim の中にあり、ここには無い

**状態は roster から入れる。** mirror の `OpenSession` は shim を持たないので、`isThinking` / `isAsking` / `isWaiting` を書く者がいない。watcher が同じ `(machineId, sessionId)` の行を受けるたびに、wire state から `isThinking`（working）/ `isAsking`（asking）/ `isWaiting`（background）を書き、`statusBar` の `model` / `messageCount` も入れる（`contextPct` は計算値で入れる口が無い。見送りに記録）。これで dot と MacroPad の key が動く。io_message を Mac 側で parse して status bar を毎 turn 更新するのはやらない（見送り）。status bar は machine 名を SSH remote と同じ位置に橙で出す

**mirror セッションがやらないこと**（shim が無いので自然に外れるものと、明示的に外すもの）：

- keep-alive、recap、title 生成、peer name、subagent 一覧：shim 経由なので自然に外れる
- **roster に publish しない。** `snapshot()` は `.mirror` origin を除く。入れると相手の Mac のセッションがこの Mac の pane として phone に二重に出て、phone の reply がこの Mac に来て失敗する
- **Save and Quit で保存しない。** `SessionRestoreSnapshot.sanitized` が `.mirror` を落とす。復元は相手の Mac の状態次第で、v1 では貼り直す方が単純（見送りに記録）
- `SessionTitleStore` に書かない。title は roster のもの
- `hasActiveSession` は shim で数えるので、mirror だけの Canopy は quit で聞かれない。正しい

**同じ remote セッションに 2 回 attach しない。** `openRemoteLive` は `(machineId, sessionId)` が一致する `.mirror` の `OpenSession` があればそのペインに focus する。1 セッション 1 ペインの不変条件はそのまま

### 5. Mac 同士の pairing

Settings › Mobile に「Other Macs」を足す。phone の Settings と同じ形。

- 「Paste Connection from Mac」：clipboard の `canopy-mirror://…` を `MirrorAccess.parseConnectionString` で読む（builder との往復を probe で固定）。`machine` が無い文字列は拒否
- 保存先：address（`host:port`）は settings.json の `canopy.mirrorPeers: [machineId: "host:port"]`、token は Keychain `sh.saqoo.Canopy.mirror-peer`（account = machineId）。settings.json に token は書かない
- 一覧に machine id と address、Forget ボタン
- pairing が無い machine の行をクリック → alert「Paste <machine>'s connection in Settings › Mobile first」。Settings を開くボタン付き

相手の Mac は `mirrorEnabled` が on で Tailscale に bind していること。off なら TCP が繋がらず `onDropped` で overlay になる。理由は分からない（見送りに記録：roster が mirror の on/off と address を運べば、行の段階で言える）

### 6. roster が open セッション全部を運ぶ

Canopy の `snapshot()`：

- `guard let paneIndex … else { continue }` を外す。pane ありは strip の index、**pane なしは pane 数からの続き番号**を `openSessions` の順で振る。phone は Mac が sort した順に描くので、phone の並びが Canopy の Open ブロックと同じになり、**今の phone をそのまま decode できる**
- **`live: Bool` を足す。** `session.shim != nil`。attach の可否はこれ 1 つで決まる（`MirrorServer.handleAttach` が見るのも shim の有無）。pane あり = shim ありではない：`openInFocusedPane` の content-swap で pane を失ったセッションは shim を持ったまま open だし、`.dormant` は open で shim が無い。`paned` では attach の可否を言えない
- `.mirror` origin は除く（上記）
- probe の key 名固定に `live` を足す。pane なしの行が続き番号で出ること、`.mirror` が出ないことも固定する

Worker：変更なし。`types.ts` の `PaneRow` に `live?: boolean` をコメント付きで足す（wire の記録として）。

phone（Canopy-Mobile、別 PR）：

- `PaneRow.live: Bool?`。nil は true 扱い（古い Mac）
- Live ボタンは `live == false` で disabled。今でも押せば server が拒否して「This session is not open on the Mac.」と出るので、押す前に分かるようにするだけ
- `RosterView` は `panes` を描くだけなので、行が増える以外の変更なし

## データの流れ

```
Mac B: RosterPublisher ──/publish──▶ relay DO "mac:B" ──/watch──▶ Mac A: RemoteRosterWatcher
                                                                        │ remoteRosters[B]
                                                                        ▼
                                                                   Sidebar: Section "B" の行
                                                                        │ click
                                                                        ▼
Mac B: MirrorServer ◀──TCP attach(token)── Mac A: RemoteMirrorBridge ◀── MirrorPaneView (pane)
       └ ShimProcess.attachMirror                                       └ OpenSession(.mirror)
```

relay が運ぶのは一覧と状態だけ。会話は Tailscale 上の TCP を直接通る。

## 変更するファイル

Canopy：

- `Roster/RemoteRosterWatcher.swift`（新規）
- `Roster/RosterSnapshot.swift`：`live`、`activity(fromWireState:)`
- `Roster/RosterPublisher.swift`：`snapshot()` の pane 限定を外す、`.mirror` 除外、`live`
- `MirrorClient.swift`（新規、`RemoteMirrorBridge` を DEBUG から移す）+ `MirrorAttachWindow.swift`（移動に追随）
- `MirrorAccess.swift`：`parseConnectionString`、peer の token 読み書き
- `MirrorPaneView.swift`（新規）
- `SessionContainer.swift`：origin で分岐
- `OpenSession.swift`：`Origin.mirror`、`localWorkingDirectory`、`mirrorBridge`
- `SidebarRow.swift`：`.remoteLive`、`RemoteLiveSession`
- `Sidebar.swift`：machine セクション、クリック経路、tooltip
- `SessionStore.swift`：`openRemoteLive`、attach 済み行の除外
- `SessionRestoreSnapshot.swift`：`.mirror` を落とす
- `CanopySettings.swift`：`mirrorPeers`
- `SettingsView.swift`：Other Macs
- `PaneHeaderMenu.swift`、`Sidebar.swift`：Finder 系を `localWorkingDirectory` に
- `CanopyApp.swift`：watcher の起動（probe guard 付き）
- `_SidebarLogicProbe.swift`

Canopy-Mobile：`worker/src/types.ts`（コメントのみ）、`RosterModels.swift`、Live ボタンの gate。

## テスト

probe で固定する純粋な部分：

- `wireState` ↔ `activity(fromWireState:)` の往復（7 case）
- `connectionString` ↔ `parseConnectionString` の往復、`machine` 欠落の拒否
- `snapshot()`：pane なし open セッションが続き番号で出る、`live` が shim の有無を映す、`.mirror` が出ない、key 名
- `SidebarRow.canOpen(.remoteLive)` が `live` に従う
- attach 済み行の除外
- `sanitized` が `.mirror` を落とす
- `openRemoteLive` の重複 attach が focus になる

実機：MBP ↔ studio。studio に Debug を rsync して `open -n --env CANOPY_MIRROR_LISTEN=<ip>:8770`、MBP の Debug で studio の接続を貼り、サイドバーの studio セクションから attach する。spike で通した rig そのまま。`mbp` は自機に折り返すので相手にならない。

## 見送り（findings）

- roster が mirror の on/off と `host:port` を運ぶ。pairing が Tailscale の IP 変更に耐え、「相手の mirror が off」を行の段階で言える
- mirror pane の status bar を io_message から毎 turn 更新する
- Save and Quit で mirror pane を復元する
- 接続断の自動再接続（今は overlay + Retry）
- mirror pane の context meter は空。`StatusBarData.contextPct` は `contextUsed` / `compactionWindow` からの計算値で、roster の百分率を入れる口が無い
- extension の版ずれ。`attach_ok` は `extensionVersion` を運ぶので、local と違えば warning を log する。挙動は未測定
- filter gear をリモート行に効かせる
- 閉じた Recents を phone に運ぶ
