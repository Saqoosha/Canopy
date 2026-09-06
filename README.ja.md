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
- **保存して終了** — ペインのレイアウトと開いていたセッションが次回起動時にそのまま戻る
- **セッション名** — そのセッション自身のコンテキストの外でタイトルを生成。サイドバー行から、またはペインヘッダーのダブルクリックでリネーム
- **Git 対応** — サイドバーとペインヘッダーに実際のブランチを表示。worktree へ移動したセッションも追従する
- **ピア名** — 他の Claude Code セッションがこのセッションを呼ぶときの名前を行に表示
- **スマホ連携** — [Canopy Mobile](https://github.com/Saqoosha/Canopy-Mobile) が複数 Mac の全ペインを一覧表示。通知への返信（自由入力、または AskUserQuestion の選択肢）が実際のユーザーターンとして入る
- **SSH リモート** — リモートマシン上の Claude CLI を SSH 経由で実行
- **Claude Code on the Web** — クラウドのセッションをローカルにテレポート
- **カスタムモデルプロバイダ** — Anthropic 互換のエンドポイントを指定し、ティアごとにモデルをマッピング
- **セッションリキャップ** — 離席から戻ると、その間に何が起きたかの要約が入力欄の上に出る
- **キャッシュ保温** — アイドルなセッションに 55 分ごとに小さなターンを 1 回投げ、プロンプトキャッシュを切らさない
- **使用量メーター** — サイドバーに 5 時間 / 週のレート制限バー、ステータスバーにペインごとのコンテキストメーター
- **リアルタイムストリーミング** — 思考、テキスト、ツール使用をライブ表示。ファイル読み込みの画像はインラインでプレビュー、サブエージェントの稼働状況もライブ表示
- **MacroPad** — 各ペインの状態を LED で示し、キーを押すとそのペインへ飛ぶ外付け USB キーパッド（任意）。返事待ちのセッションが画面を見ずに分かる。USB 直結でも、別の Mac から TCP 経由でも駆動できる（ファームウェアとケース: [Canopy-MacroPad](https://github.com/Saqoosha/Canopy-MacroPad)）
- **自動アップデート** — Sparkle によるデルタアップデート対応
- **キーボードショートカット** — Cmd+N（新規セッション）、Cmd+O（フォルダを開く）、Cmd+1–9（ペインをフォーカス）、Cmd+Ctrl+1–9（N 番目のセッションをフォーカス中のペインに読み込む）、Cmd+Shift+[ / ]（フォーカス中のペインのセッションを切り替え）、Cmd+Opt+←/→（フォーカス移動）
- **カスタムスタイル** — タイポグラフィ、コードブロック、シンタックスハイライトを調整し、ネイティブ macOS に馴染む見た目に

## 必要なもの

- macOS 15.0 (Sequoia) 以降
- [Claude Code VSCode 拡張機能](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)（`claude auth login` で認証済み）
- Node.js 18+

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
WKWebView ─── postMessage ──→ ShimProcess.swift
                                  │ stdin/stdout NDJSON
                                  ▼
                              Node.js subprocess
                                  ├─ vscode-shim/ (10 JS modules)
                                  │    └─ intercepts require("vscode")
                                  └─ extension.js (CC extension, unmodified)
                                       └─ spawns Claude CLI via child_process
```

CC 拡張機能の `extension.js` を未改変のまま Node.js サブプロセスで実行。vscode-shim が `require("vscode")` を横取りし、NDJSON（stdin/stdout）経由で webview とブリッジ。拡張機能が Claude CLI をストリーミング JSON モードで起動し、SSE イベントがそのまま webview に流れる。

SSH リモートでは、ラッパースクリプトが CLI の起動を置き換え、SSH 経由でリモートマシン上の `claude` を実行。

### プロジェクト構成

```
Sources/Canopy/
  CanopyApp.swift              SwiftUI アプリエントリ、ペイン、メニュー、Sparkle アップデーター
  SessionActivity.swift        サイドバーのドットと MacroPad の LED が共有する状態分類
  MacroPad/                    USB キーパッド: ワイヤプロトコル、シリアル/TCP デバイス、状態コントローラ
  Roster/                      スマホ連携: ペイン一覧の発行、プッシュ通知、返信
  SessionStore.swift           サイドバーとペインの状態、開閉、フォーカス、並び順
  SessionRestoreSnapshot.swift 「保存して終了」のスナップショットと復元ルール
  KeepAliveCoordinator.swift   プロンプトキャッシュ保温のクロックと配信
  RecapCoordinator.swift       離席から戻ったときのリキャップ生成
  SessionTitleGenerator.swift  セッション外でのタイトル生成
  AppState.swift               状態管理、PermissionMode enum、画面遷移
  ShimProcess.swift            Node.js サブプロセス管理、NDJSON ブリッジ、認証パッチ
  NodeDiscovery.swift          Node.js >= 18 の検出 (Homebrew, mise, nvm, login shell)
  LauncherView.swift           ランチャー: ディレクトリ選択、履歴
  WebViewContainer.swift       WKWebView セットアップ、CSS インジェクション
  ClaudeSessionHistory.swift   セッション JSONL パーサー
  StatusBarView.swift          ネイティブステータスバー: コンテキスト使用量、モデル、レート制限
  ContentViewer.swift          Monaco エディタオーバーレイ
  theme-light.css              VSCode CSS 変数 456 個 (Default Light+)

Resources/
  vscode-shim/                 VSCode API を shim する Node.js モジュール群
  ssh-claude-wrapper.sh        SSH リモート用ラッパースクリプト
  canopy-overrides.css         カスタムスタイル: タイポグラフィ、コードブロック、WKWebView 修正
  prism-canopy.css             シンタックスハイライトテーマ (Prism.js, Claude Desktop 風配色)
```

### テスト

```bash
# ユニットテスト
node --test test/shim-unit.test.js

# インテグレーションテスト (CC 拡張機能が必要)
node --test --test-timeout 120000 test/shim-integration.test.js
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
