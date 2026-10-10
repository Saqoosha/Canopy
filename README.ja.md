[English](README.md) | 日本語

# Canopy

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="Canopy icon">
  <br>
  <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> をネイティブ macOS アプリで使える — VSCode 不要。Claude Code 拡張機能の UI をそのまま macOS ウィンドウで動かします。
</p>

<p align="center">
  <img src="images/screenshot.png" width="800" alt="Canopy スクリーンショット">
</p>

## 特徴

- **ネイティブ macOS ウィンドウ** — Claude Code の React UI を WKWebView で表示
- **ランチャー** — ディレクトリ選択、最近のディレクトリ、セッション履歴、モデル/エフォート/パーミッション選択、GitHub からのクローン、「新しい worktree で開始」トグル
- **サイドバーシェル** — セッションは左サイドバーに常駐し、詳細ペインがその場で webview を差し替える
- **分割ビュー** — 最大 6 ペインを横に並べ、Cmd+1–9 でフォーカス、ディバイダのドラッグでリサイズ
- **セッション再開** — 過去のセッションを履歴の即時リプレイで再開
- **ウィンドウを閉じてもセッションが続く** — セッションはバックグラウンドのサービスで動くので、アプリを終了しても止まらない。開き直すとペインが再び attach する。アプリの更新ではサービスが再起動し、セッションは transcript から再開する
- **他の Mac のセッション** — 別の Mac で動くセッションを Tailscale 経由で開き、再開し、transcript ごと見られる。ランチャーからその Mac で新しいセッションを起動し、フォルダを選び、セッションを止められる
- **保存して終了** — ペインのレイアウトが次回起動時にそのまま戻る
- **セッション名** — そのセッション自身のコンテキストの外でタイトルを生成。サイドバー行から、またはペインヘッダーのダブルクリックでリネーム
- **Git 対応** — サイドバーとペインヘッダーに実際のブランチを表示。worktree へ移動したセッションも追従する
- **ピア名** — 他の Claude Code セッションがこのセッションを呼ぶときの名前を行に表示
- **スマホ連携** — [Canopy Mobile](https://github.com/Saqoosha/Canopy-Mobile) が複数 Mac の全ペインを一覧表示。通知への返信（自由入力、または AskUserQuestion の選択肢）が実際のユーザーターンとして入る
- **Control API** — スクリプトや別のエージェントが、ペインを開かずに、ローカルの socket からセッションを起動し、ターンを送り、返事を待ち、permission の要求を待ち受けられる（[docs/CONTROL_PROTOCOL.md](docs/CONTROL_PROTOCOL.md)、`scripts/canopyctl`）
- **複数の Claude アカウント** — ログインを追加し、セッションごとに選べる。上限に達したセッションは別のログインに切り替えられる
- **SSH リモート** — Linux、WSL、Windows のホスト上の Claude CLI を SSH 経由で実行
- **Claude Code on the Web** — クラウドのセッションをローカルにテレポート
- **カスタムモデルプロバイダ** — Anthropic 互換のエンドポイントを指定し、ティアごとにモデルをマッピング
- **セッションリキャップ** — 離席から戻ると、その間に何が起きたかの要約が入力欄の上に出る
- **キャッシュ保温** — アイドルなセッションに 55 分ごとに小さなターンを 1 回投げ、プロンプトキャッシュを切らさない
- **使用量メーター** — サイドバーにアカウントごとの 5 時間 / 週のレート制限バー（色はペースで決まる）、ステータスバーにペインごとのコンテキストメーター
- **作業中はスリープしない** — セッションが作業中の間、蓋を閉じていても Mac は idle sleep しない。設定で、セッションが開いている間ずっと起こしておき、スマホから届くようにもできる。バッテリーが下限を切ったら sleep する
- **リアルタイムストリーミング** — 思考、テキスト、ツール使用をライブ表示。ファイル読み込みの画像はインラインでプレビュー、サブエージェントの稼働状況もライブ表示
- **MacroPad** — 各ペインの状態を LED で示し、キーを押すとそのペインへ飛ぶ外付け USB キーパッド（任意）。返事待ちのセッションが画面を見ずに分かる。USB 直結でも、別の Mac から TCP 経由でも駆動できる（ファームウェアとケース: [Canopy-MacroPad](https://github.com/Saqoosha/Canopy-MacroPad)）
- **自動アップデート** — Sparkle によるデルタアップデート対応。更新は、作業を失うセッションがなくなるか Restart now を押すまで待つ。Claude Code 拡張機能の更新は、新しい版が起動することを確かめてから自動で入る
- **キーボードショートカット** — Cmd+N（新規セッション）、Cmd+O（フォルダを開く）、Cmd+1–9（ペインをフォーカス）、Cmd+Ctrl+1–9（N 番目のセッションをフォーカス中のペインに読み込む）、Cmd+Shift+[ / ]（フォーカス中のペインのセッションを切り替え）、Cmd+Opt+←/→（フォーカス移動）、Cmd+W（フォーカス中のペインを閉じる。最後の 1 つを閉じるとランチャーに戻る）、Cmd+Opt+W（フォーカス中のペインのセッションを停止）、Cmd+Shift+W（ウィンドウを閉じる）
- **カスタムスタイル** — タイポグラフィ、コードブロック、シンタックスハイライトを調整し、ネイティブ macOS に馴染む見た目に

## 必要なもの

- macOS 15.0 (Sequoia) 以降
- [Claude Code VSCode 拡張機能](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)（`claude auth login` で認証済み）
- Node.js 18+

## Control API

Canopy のセッションサービスはローカルの Unix socket で待ち受けている。スクリプトや別のエージェントが、ペインなしでセッションを動かせる。このリポジトリの `scripts/canopyctl` がそのクライアント（Python 3、標準ライブラリのみ）。既定では、インストール済みのアプリのサービスにつなぐ。

```bash
# 最初のプロンプト付きでセッションを起動。sessionId、key、replyId を出力する
scripts/canopyctl open --cwd ~/repos/my-project --initial-prompt "Run the tests and summarize the failures"

# そのターンの返事を待つ
scripts/canopyctl wait --key <key> --reply-id <replyId>

# 次のターンを送る
scripts/canopyctl send --key <key> --text "Fix the first failure"

# 何かが起きるまで待つ: ターンの終了、permission の要求、質問
scripts/canopyctl listen --key <key>

# 過去のセッションを 1 行ずつ表示。続けるには `resume <sessionId>`
scripts/canopyctl sessions --project my-project --table
```

verb の一覧、パラメータ、終了コードは [docs/CONTROL_PROTOCOL.md](docs/CONTROL_PROTOCOL.md) にある。

---

## 開発

### 必要なもの

- Xcode 26（16.4 ではビルドが通らない）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### ソースからビルド

```bash
git clone https://github.com/Saqoosha/Canopy.git
cd Canopy
xcodegen generate
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build

# アプリの場所:
# build/Build/Products/Debug/Canopy.app
```

### アーキテクチャ

```
Canopy.app (この Mac)    Canopy.app (別の Mac)    Canopy Mobile (iPhone)
        │ Unix socket            │ TCP over Tailscale        │
        └──────────────┬─────────┴───────────────────────────┘
                       ▼
canopyd  (Canopy.app --daemon、Mac ごとに 1 つの LaunchAgent)
  ├─ ControlSession   一覧 / 起動 / 停止 / subscribe / send_message / listen
  ├─ MirrorServer     attach、transcript の replay、asset
  ├─ RosterPublisher  roster、セッションのイベント、通知 → Cloudflare relay
  └─ ShimProcess × N
        │ stdin/stdout NDJSON
        ▼
     Node.js vscode-shim  ── require("vscode") を横取り
        └─ extension.js (Claude Code 拡張機能、未改変)
             └─ claude CLI (stream-json)
```

Claude Code 拡張機能の `extension.js` を未改変のまま Node.js サブプロセスで実行。vscode-shim が `require("vscode")` を横取りし、拡張機能の webview と NDJSON でブリッジ。拡張機能が Claude CLI をストリーミング JSON モードで起動し、SSE イベントは shim での CJK の太字の修復を除いて、変換されずに webview に届く。

3.0 から、セッションは **canopyd** が持つ。launchd が起動するバックグラウンドのデーモンで、同じバイナリを `--daemon` 付き・`NSApplication` なしで動かしたもの。Mac アプリはクライアントで、各ペインは Unix socket でデーモンに attach する。別の Mac のペインやスマホが Tailscale 経由で attach するのと同じ経路。ペインを閉じても detach するだけで、セッションは停止されるか、誰も見ていない idle 状態が設定の時間（既定 4 時間）続くまで走り続ける。スクリプトは control API で同じ socket を使う。

デーモンが動かないホスト（Linux、WSL、Windows）には SSH リモートを使う。ラッパースクリプトが CLI の起動を置き換え、SSH 経由でホスト上の `claude` を実行。

全体の説明は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)（英語）。図つきの説明は [saqoosha.github.io/Canopy/architecture.html](https://saqoosha.github.io/Canopy/architecture.html)。ソースは [docs/architecture.html](docs/architecture.html)。

### プロジェクト構成

```
Sources/Canopy/
  CanopyMain.swift             エントリポイント: GUI か、--daemon ならデーモンを起動
  CanopyDaemon.swift           デーモンの run loop、起動と終了
  DaemonSupervisor.swift       ペインが attach する前にデーモンが応答することを確かめる
  DaemonUpgrade*.swift         失うものがなくなったら新しいビルドでデーモンを再起動
  ControlProtocol.swift        control 接続: hello、verb、session_state の push
  ControlSession.swift         control 接続のデーモン側
  ControlEvents.swift          control API の listen が読むイベントログ
  MirrorServer.swift           session 接続: attach、replay、asset、ファイル転送
  MirrorPaneView.swift         デーモンのセッション（この Mac・別の Mac）に attach するペイン
  CanopyApp.swift              SwiftUI アプリエントリ、ペイン、メニュー、Sparkle アップデーター
  SessionActivity.swift        サイドバーのドットと MacroPad の LED が共有する状態分類
  SleepGuard.swift             セッションが作業中の間 Mac を起こしておく（蓋を閉じていても）
  ClaudeAccount.swift          追加の Claude ログイン。1 つにつき CLAUDE_CONFIG_DIR が 1 つ
  ExtensionUpdater.swift       Claude Code 拡張機能の更新をダウンロードしてインストール
  MacroPad/                    USB キーパッド: ワイヤプロトコル、シリアル/TCP デバイス、状態コントローラ
  Roster/                      スマホ連携: ペイン一覧の発行、プッシュ通知、返信
  SessionStore.swift           セッションの registry（デーモン側）とサイドバー・ペインの状態（GUI 側）
  SessionRestoreSnapshot.swift 「保存して終了」のスナップショットと復元ルール
  KeepAliveCoordinator.swift   プロンプトキャッシュ保温のクロックと配信
  RecapCoordinator.swift       離席から戻ったときのリキャップ生成
  SessionTitleGenerator.swift  セッション外でのタイトル生成
  AppState.swift               状態管理、PermissionMode enum、画面遷移
  ShimProcess.swift            セッション 1 つ分の Node.js サブプロセス、NDJSON ブリッジ、トラッカー、クライアントへの配信
  NodeDiscovery.swift          Node.js >= 18 の検出 (Homebrew, mise, nvm, login shell)
  LauncherView.swift           ランチャー: ディレクトリ選択、履歴
  WebViewContainer.swift       WKWebView セットアップ、CSS インジェクション
  ClaudeSessionHistory.swift   セッション JSONL パーサー
  StatusBarView.swift          ネイティブステータスバー: コンテキスト使用量、モデル、レート制限
  ContentViewer.swift          Monaco エディタオーバーレイ
  theme-light.css              VSCode CSS 変数 456 個 (Default Light+)

Resources/
  vscode-shim/                 VSCode API を shim する Node.js モジュール群
  canopy-bridge/               コンテキストの上限を Canopy に伝える Claude Code の Mod
  ssh-claude-wrapper.sh        SSH リモート用ラッパースクリプト
  canopy-overrides.css         カスタムスタイル: タイポグラフィ、コードブロック、WKWebView 修正
  prism-canopy.css             シンタックスハイライトテーマ (Prism.js, Claude Desktop 風配色)

scripts/
  canopyctl                    control API のクライアント (Python、標準ライブラリのみ)
```

### テスト

```bash
# shim のユニットテスト (CI が走らせる一覧)
node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)

# インテグレーションテスト (CC 拡張機能が必要)
node --test --test-timeout 120000 test/shim-integration.test.js

# Swift のロジック probe (約 3 秒。実際の UserDefaults と ~/.claude に書く。docs/notes/testing.md 参照)
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

### リリース

```bash
# フルリリース: ビルド、署名、公証、DMG、GitHub Release、Sparkle appcast
./scripts/release.sh 1.0.2

# appcast のみ更新 (GitHub Release のノート編集後)
./scripts/update_appcast.sh 1.0.2
```

### サードパーティライブラリ

- [Sparkle](https://github.com/sparkle-project/Sparkle) — macOS 用自動アップデートフレームワーク

## ライセンス

MIT
