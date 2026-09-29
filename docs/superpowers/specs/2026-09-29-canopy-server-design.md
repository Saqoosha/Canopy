# Canopy Server — session を daemon に持たせ、Mac と iPhone を対等な client にする

2026-09-29。設計。Plan A（daemon と control API）は PR #267。

## 目標

1. **(a) SSH remote の置き換え。** 他の Mac で session を開き、resume し、transcript が描かれる。今の SSH remote では transcript も `@`-mention も出ない（[2026-09-09-ssh-remote-boundary.md](2026-09-09-ssh-remote-boundary.md)）
2. **(b) iPhone から、どの Mac のどのフォルダでも、どの古い session でも開ける。** 今の phone は、Mac で開いている session に attach することしかできない

対象は Mac だけ。Linux / WSL / Windows のサーバは扱わない。

## 背景

同期の機能を 1 本ずつ足してきた結果、Canopy.app はすでに半分サーバになっている。`Mirror*.swift` と `Roster/*.swift` で約 5,000 行。

- `SessionStore.startHeadlessSession`：pane を持たない session を shim ごと起動する。新規も resume もできる
- `MirrorServer`：`attach`、`get_session_request` による transcript の replay、`asset_request` による webview asset の配信、`list_recents`（session 20 件、フォルダ 10 件）
- #266：他の Mac の Recents を launcher に出し、クリックすると向こうで headless session を起こして attach する
- relay：マシン一覧と、各マシンの open session の roster

問題は、どれも「GUI アプリの中にいるサーバ」に後付けしていること。session の持ち主（`SessionStore`）と、pane への表示が同じ場所で混ざっている。そのせいで、roster から `.mirror` を除外する、二重表示を防ぐ、といった分岐が増え続けている。

2026-09-09 のメモでは、この形（案 C、herdr 型 daemon）を「利点は永続化だけで、その要求はまだ来ていない」として保留した。今回、(a)(b) に加えて「アプリを閉じても session が続く」ことを選んだので、判断を変える。

## プロセスの境界

```
┌─ Canopy.app (client) ─────────┐        ┌─ iPhone (client) ─┐
│ sidebar / panes / MacroPad    │        │                   │
│ WKWebView ×N  ContentViewer   │        └────────┬──────────┘
└──────┬────────────────────────┘                 │
       │ Unix socket (local)   TCP over Tailscale (remote)
       ▼                                          ▼
┌─ canopyd (各 Mac に 1 つ、LaunchAgent) ────────────────────┐
│ session registry                                           │
│ ShimProcess ×N → node shim → extension.js → CLI            │
│ recents・folders・titles                                   │
│ keep-alive / recap / title / bg reconcile / phone reply    │
│ MirrorServer（attach, replay, asset, control verbs）       │
│ RosterPublisher → Cloudflare relay                         │
└────────────────────────────────────────────────────────────┘
```

- **daemon は同じ binary の別モード。** `Canopy.app/Contents/MacOS/Canopy --daemon` を、window を出さない accessory アプリとして起動する。登録は `SMAppService.agent` で、plist はバンドル内に置く。別 target にすると、`ShimProcess` を WebKit から切り離す作業が phase 1 の前提になってしまう。同じ binary なら、それを後回しにできる。daemon のプロセスに WebKit がリンクされていても害はない
- **LaunchAgent であって LaunchDaemon ではない。** CLI の OAuth は login keychain にある。2026-09-09 の実測で、Aqua セッションの外（SSH セッション）からは login keychain を解錠できなかった（`security find … -w` が exit 36）。LaunchAgent なら Aqua セッションの中で動く。その代わり、ユーザがログインしていないマシンでは動かない
- **登録は Release の GUI が起動するたびに確認する。** 未登録なら登録し、登録済みなら何もしない。Debug は `CANOPY_REGISTER_DAEMON=1` のときだけ登録し、`--unregister-daemon` で外す。macOS が初回に「ログイン項目に追加されました」を通知するので、ユーザは System Settings から外せる。承認待ち（`.requiresApproval`）を知らせる UI は Plan B
- **Canopy.app は純粋な client になる。** local の pane も、今の `.mirror` pane（`MirrorPaneView` + `RemoteMirrorBridge`）と同じ経路で繋ぐ。違うのは transport（Unix socket か TCP か）だけ
- **iPhone は同じプロトコルの client の 1 つ**
- **SSH remote モードは消す。** remote マシンとは「`canopyd` が動いている Mac」のこと。remote の Mac に Canopy が入っている必要がある

### WebKit と AppKit への依存

`ShimProcess.swift`（約 8,000 行）で `webView` を参照している箇所は 20 数箇所。中身は 4 種類だけで、どれも client へのメッセージに置き換える。

| 今の呼び出し | 置き換え |
|---|---|
| primary webview への送信 | 他の `MirrorSink` と同じ扱い。primary という特別な枠をなくす |
| recap の `evaluateJavaScript` | 注入する JS を session 接続で client に送り、client が評価する |
| `ContentViewer.show`、`NSWorkspace.open` | `show_content` / `open_file` / `open_url` を client に送る |
| `UNUserNotificationCenter` | `notify` を client に送る |

重い結びつきは WebKit ではなく、`OpenSession` / `SessionStore` / `StatusBarData` / `SharedRateLimitData` との結びつきのほう。phase 1 では daemon モードでもこれらの型をそのまま使い、分離はしない。

## API

土台は今の `MirrorServer` のプロトコル（NDJSON、最初の行で認証、`Z` 圧縮、`asset_request`）。

### 接続

- **control 接続**：client ごとに 1 本。一覧の取得、session の起動と停止、状態変化の push
- **session 接続**：attach している session ごとに 1 本。今の `attach` と同じで、webview の NDJSON がそのまま流れる。1 session 1 接続は 2026-09-14 のスパイクで実測済みの形なので変えない

control 接続の最初の行は `hello {token, protocolVersion}`、session 接続の最初の行は今の `attach`。control 接続は daemon の listener だけが受け付ける。

- local の Unix socket はファイルの権限（0600、所有者のみ）で守る。token は要らない
- daemon と app は同じバンドルで配るので、local では通常バージョンが一致する（アップデート後に古い daemon が残っていれば別）。remote とはずれることがある。`protocolVersion` が合わなければ、daemon は理由付きの `hello_error` を返して切る
- token は今の `MirrorAccess` のものを使う

### control の verb

| verb | 返すもの / 効果 | 置き換える今のもの |
|---|---|---|
| `list_sessions {scope: "open"\|"recent", query?, limit}` | session の配列（id、title、project、cwd、state、lastActiveAt、running） | `list_recents`、roster |
| `list_folders {limit}` | 最近のフォルダ | `list_recents` |
| `browse_dir {path}` | そのディレクトリのエントリ | `RemoteDirectoryBrowser` の SSH 版 |
| `mkdir {parent, name}` | フォルダ作成 | `RemoteDirectoryBrowser` の New Folder |
| `open_session {cwd, model?, effort?, permissionMode?, worktreeBranch?, initialPrompt?}` | `{sessionId, cwd}`。`bypassPermissions` はその Mac の opt-in が無ければ拒否 | launcher → `SessionStore.openNew` |
| `stop_session {sessionId}` | daemon 側で shim を止める | `closeSession` |
| `rename_session` / `switch_account` / `restart_session` | 各操作 | `SessionStore` の各メソッド |
| `subscribe` | 以後 `session_state` を push | roster、`MirrorStatusFrame`、`MirrorUsageFrame` |

### server から client へ（session 接続の上）

`show_content`、`open_file`、`open_url`、`notify`、`eval_js`（recap の描画）、ファイル転送（今の `MirrorFileTransfer`）。

`notify` は attach している client にしか届かない。どの client も繋いでいないときの通知は、今の relay 経由の push（phone）に任せる。

## session のライフサイクル

- **attach は resume を兼ねる。** 走っていない session に `open` 付きの `attach` をしたら、daemon がその場で resume する。「古い session を開く」「止まった session に戻る」「アプリ再起動後の復元」が 1 本の経路になる
- **pane を閉じる（Cmd+W）は detach。** session は daemon 上で走り続け、全 client の Open 一覧に残る。daemon 側を止めるのは明示的な Stop Session だけ
- **reaper**：どの client も attach しておらず、working でも asking でもなく、permission 待ちや背景タスクも無い状態が **15 分**続いた session は daemon が止める。止めても closed 行に戻るだけで、どこからでも resume できるので、長く生かしておく理由はない。shim 1 本（node + CLI）は数百 MB を使う
- **keep-alive の対象**は「client が 1 つ以上 attach している session」に変わる。reaper で止まる session のキャッシュを温めても意味がない
- **daemon の再起動**（アップデートで binary が差し替わる）では、session は全部止まる。daemon は何も持ち越さない。client が attach し直せば resume される
- **Save-and-Quit** は client 側で `(machineId, sessionId)` ごとの pane 配置だけを保存する。起動したら attach するだけ。`OpenSession.Status.dormant` は不要になる

## 状態の持ち主

| 状態 | 持ち主 | 今の場所 |
|---|---|---|
| 走っている session、shim、activity | daemon | `SessionStore.openSessions` |
| recents、フォルダ、タイトル、hidden | daemon（マシンごと） | app の UserDefaults（`RecentDirectories`、`SessionTitleStore`） |
| session に効く設定（既定の permission、keep-alive、recap、worktree seed、アカウント、model provider） | daemon | `CanopySettings`、`ClaudeAccountStore`、`ModelProviderStore` |
| rate limit | daemon が集計して push | `SharedRateLimitData` |
| pane の並びと幅、window、filter、MacroPad、sidebar の折りたたみ | client | そのまま |

### Cloudflare relay に載せるもの

- **載せる**：マシン一覧、presence、Tailscale アドレス、open session とその状態（今の roster）
- **載せない**：recents とフォルダ。client がそのマシンの daemon に直接 `list_sessions` で聞く。オフラインのマシンの recents は見えないが、どうせ開けない。relay に index を持たせると、同期の二重持ちがまた生まれる
- 会話の中身は Tailscale 直結のまま

### client の組み立て

client は relay からマシン一覧を取り、到達できる daemon ごとに control 接続を 1 本張る（local は Unix socket）。サイドバーは、マシンごとの `subscribe` の push を並べたもの。

`OpenSession.Origin` の `.local` / `.remote` / `.mirror` は、`machineId` を持つ 1 つの形にまとまる。local と remote の違いは、どのマシンかというラベルだけになる。

## Phase 1

phase 1 が目標 (a)(b) そのもの。

1. **daemon モード**：`--daemon` で起動し、headless session だけを持つ。`MirrorServer` を Unix socket と、Mirror が On のときは Tailscale でも listen する。`SMAppService` で登録する
2. **control verb**：上の表。attach→resume と reaper を入れる
3. **app を client にする**：サイドバーと launcher を、マシンごとの control 接続の上に組み直す。local の pane も `MirrorPaneView` 経由にする。daemon が動いていなければ app が登録して起動する
4. **phone**：Canopy-Mobile 側。マシンを選ぶ → recents / フォルダ / `browse_dir` → 開く。別リポジトリなので別 PR
5. **消す**：SSH remote（`ssh-claude-wrapper.sh`、`CANOPY_REMOTE_*` / `CANOPY_SSH_*`、`vscode-shim/index.js` の SSH パッチ、`RemoteSessionHistory`、`RemoteDirectoryBrowser` の SSH 実装）、app 内の in-process session 経路、`.dormant`、#266 の `MirrorRecents` 経路

1〜3 が (a)、2 と 4 が (b)。5 は 3 が動いてから。

### phase 1 に入れないもの

- `ShimProcess` の WebKit 分離と別 target 化
- `ShimProcess` の分割
- Linux / Windows のサーバ
- ユーザがログインしていないマシンで動かすこと（LaunchDaemon）

## テスト

- **値型は probe で固定する。** verb の encode/decode、`hello` のバージョン判定、reaper の判定、attach→resume の分岐を純粋な値型に切り出し、`_SidebarLogicProbe` から届くようにする
- **Debug と Release を分ける。** `~/Library/Application Support/Canopy` は両方で共有されている（CLAUDE.md の entry-file の learning を参照）。socket のパスと LaunchAgent のラベルは bundle id から作る（`sh.saqoo.Canopy.debug`）。そうしないと、Debug の daemon が Release の socket を奪う
- **daemon モードも probe の guard を持つ。** `CANOPY_RUN_LOGIC_PROBE=1` で daemon を登録・起動しない
- **remote の実測は studio で。** `mbp` は Tailscale でこのマシン自身に戻る
- **受け入れ条件**
  - この Mac の Canopy から、studio の daemon 上で新規 session を開き、古い session を resume し、どちらも transcript が描かれる
  - iPhone から studio の任意のフォルダ（Recents にないもの）で session を開ける
  - Canopy.app を終了しても session が生きていて、再起動すると同じ pane 配置で attach し直せる
  - どの client も attach していない idle な session が、15 分後に止まる

## 未決

- daemon の設定をどの client から変えるか。remote の daemon の設定を、この Mac の Settings から変えられるようにするか

複数の client が同じ session に attach しているときの permission / `AskUserQuestion` への応答は、Canopy Mobile で解決済みの仕組みをそのまま使う。新しく決めることはない。
