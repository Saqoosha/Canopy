# Canopy から CLI に Mod を 1 つ読ませ、コンテキストメーターの分母を CLI の値にする

コンテキストメーターは、CLI が出すフレームから値を組み立てている。分子は `message_start` / `assistant` の usage の合計、分母は `result.modelUsage` を `system/init` のモデル名で引いた `contextWindow`。モデル名の照合（issue #108）、サブエージェントの除外、最初の `result` までの空白、ディレクトリ単位の復元キャッシュは、どれもこの組み立てから生まれた問題。

Claude Code の Mod（function hooks）の `session.measure` は、メイン会話の応答のあと、値が動いていれば `context.tokens` / `context.window` を通知する。このうち `window` を Canopy に渡す。

## spike で確かめたこと（2026-10-02）

- `$.ui.log(text)` は stream-json に `{"type":"system","subtype":"ui_log","plugin":<name>,"text":…}` として出る。JSONL には書かれない。
- `CLAUDE_CODE_PLUGIN_DIRS` を shim の環境に入れると、エクステンションを経由して CLI まで継承される。`ui_log` は shim の stdout に、ほかの CLI フレームと同じ封筒（`webview_message → from-extension → io_message`）で届く。エクステンション 2.1.286（現行の同梱版）と 2.1.287 の両方で確認した。
- webview のコードに `ui_log` を扱う部分は無い。
- `session.measure` の `context.tokens` は、`message_start` の合計（`input + cache_creation + cache_read`）と一致した（Haiku、39785）。ただし応答が終わってから届くので、`message_start` より 1 回分遅い。出力トークンも含まない。
- `window` は最初の API 呼び出しより前に届いた（既定モデルで 1,000,000）。サブエージェント（Haiku）が走っても、値はメイン会話のものだった。`/compact` のターンでは何も届かなかった。
- CLI は Mod を読み込むたびに、そのフォルダへ `.claude-plugin/types/` と `tsconfig.json` を書き込む。

## 決めたこと

- **Mod は `Resources/canopy-bridge/` に置き、使う前に `~/Library/Application Support/Canopy/mods/<bundle id>/canopy-bridge/` へコピーする。** フォルダを bundle id で分けるのは、Debug と Release が同じフォルダを上書きし合わないようにするため。バンドルから直接読ませると、CLI の書き込みで署名が壊れる。コピーは `ShimProcess.start()` の中で行い、中身が同じなら何もしない。daemon も GUI も同じ経路を通る。
- **`CLAUDE_CODE_PLUGIN_DIRS` は、引き継いだ値の前に自分のパスを `:` で足す。** ユーザーが自分で設定した Mod を消さない。同じパスがすでにあれば重ねない（Canopy の中から起動した Canopy が引き継ぐ）。SSH remote では、wrapper がこの変数を転送しないので、リモートの CLI には届かない。
- **Mod は `session.measure` で `context` が変わったときだけ、`ui_log` を 1 行出す。** 中身は `{"v":1,"context":{"tokens":…,"window":…}}`。
- **ShimProcess は、`plugin == "canopy-bridge"` の `ui_log` を、ほかのどの処理よりも先に飲み込む。** webview には送らない。解析は純粋関数にして、probe で固定する。
- **bridge から取るのは `contextMax`（window）だけ。** `contextUsed` は今までどおり `message_start` / `assistant` から取る。そちらはもともとメイン会話だけを見ていて、bridge より早い。#108 の問題は分母の側にしかなかった。window が一度届いたシェルでは、`result` は `contextMax` を書かない（`maxOutputTokens` は書き続ける）。bridge が届かない場合（SSH remote、Mod が読み込まれなかった場合）は、今の経路がそのまま動く。

## 確かめること（実機）

- Debug ビルドでセッションを開いて 1 往復し、`[bridge] context window from the CLI` のログとメーターの分母を確かめる。

## 範囲外（findings）

- `session.measure` のレート制限で、サイドバーの使用量を置き換える。
- keep-alive を `$.model.fork` に置き換える（TTL の実測待ち）。
- バックグラウンドタスクの完了と、セッションの relocation を、Mod のイベントで受け取る。
