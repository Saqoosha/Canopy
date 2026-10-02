# Canopy から CLI に Mod を 1 つ読ませ、コンテキストメーターを CLI の値で描く

コンテキストメーターは、CLI が出すフレームから値を組み立てている。分子は `message_start` / `assistant` の usage の合計、分母は `result.modelUsage` を `system/init` のモデル名で引いた `contextWindow`。モデル名の照合（issue #108）、サブエージェントの除外、最初の `result` までの空白、ディレクトリ単位の復元キャッシュは、どれもこの組み立てから生まれた問題。

Claude Code の Mod（function hooks）の `session.measure` は、ステータスラインが使う値そのもの（`context.tokens` / `context.window`）を、値が変わるたびに通知する。この値を Canopy に渡す。

## spike で確かめたこと（2026-10-02）

- `$.ui.log(text)` は stream-json に `{"type":"system","subtype":"ui_log","plugin":<name>,"text":…}` として出る。JSONL には書かれない。
- `CLAUDE_CODE_PLUGIN_DIRS` を shim の環境に入れると、エクステンションを経由して CLI まで継承される。`ui_log` は shim の stdout に、ほかの CLI フレームと同じ封筒（`webview_message → from-extension → io_message`）で届く。エクステンション 2.1.286（現行の同梱版）と 2.1.287 の両方で確認した。
- webview のコードに `ui_log` を扱う部分は無い。
- `session.measure` の `context.tokens` は、旧来の計算（`input + cache_creation + cache_read`）と一致した（Haiku、39785）。`window` は最初の API 呼び出しより前に届く。
- CLI は Mod を読み込むたびに、そのフォルダへ `.claude-plugin/types/` と `tsconfig.json` を書き込む。

## 決めたこと

- **Mod は `Resources/canopy-bridge/` に置き、使う前に `~/Library/Application Support/Canopy/mods/canopy-bridge/` へコピーする。** バンドルから直接読ませると、CLI の書き込みで署名が壊れる。コピーは `ShimProcess.start()` の中で行い、中身が同じなら何もしない。daemon も GUI も同じ経路を通る。
- **`CLAUDE_CODE_PLUGIN_DIRS` は、引き継いだ値の前に自分のパスを `:` で足す。** ユーザーが自分で設定した Mod を消さない。SSH remote でも設定する。ローカルの CLI を起動しないので、何も起きない。
- **Mod は `session.measure` で `context` が変わったときだけ、`ui_log` を 1 行出す。** 中身は `{"v":1,"context":{"tokens":…,"window":…}}`。
- **ShimProcess は、`plugin == "canopy-bridge"` の `ui_log` を、ほかのどの処理よりも先に飲み込む。** webview には送らない。解析は純粋関数にして、probe で固定する。
- **bridge の値が一度届いたシェルでは、旧来の経路は `contextUsed` / `contextMax` を書かない。** 1 つの値を 2 つの経路で書くと、最後に書いた方が勝ち、表示が揺れる。`maxOutputTokens` は measure に入っていないので、`result` から取り続ける。bridge が届かない場合（SSH remote、Mod が読み込まれなかった場合）は、今の経路がそのまま動く。

## 確かめること（実機）

- サブエージェントを走らせたときに、`context.tokens` がメイン会話の値のままか。
- `/compact` のあとに、値が下がるか。
- 既定のモデル（`[1m]`）で、`window` が 1,000,000 になるか。

## 範囲外（findings）

- `session.measure` のレート制限で、サイドバーの使用量を置き換える。
- keep-alive を `$.model.fork` に置き換える（TTL の実測待ち）。
- バックグラウンドタスクの完了と、セッションの relocation を、Mod のイベントで受け取る。
