# Canopy のセッションを Slack スレッドに紐付け、スレッドの参加者が直接質問できるようにする

例：委託契約のスレッド（`C089F5P7R9P`）で話している内容を、outsourcing-contract セッションに直接聞けるようにする。Saqoosha がスレッドの内容をコピーしたり「スレッド見て」と頼んだりしなくて済む。

質問するのは Saqoosha 本人とは限らない。セッションは Saqoosha の Mac の上で、Saqoosha の権限のまま動いている。だから設計の中心は、他人の質問にセッションが何をしてよいかを決めること。

## 実測したこと（2026-10-22）

- **Saqoolaude の権限**: `slack-app-manifest.yaml` に `channels:history` / `groups:history` と、`message.channels` / `message.groups` のイベントがある。これで `conversations.replies` によるスレッドの読み取りと、メンションの受信ができる。`app_mention` は無いので、本文に bot の user id があるかで判定する。
- **ターンの出どころの判定**: mod の `turn.start` では、ターンの本文と `turnId` が読める。本文が `[canopy:slack]` で始まるターンを Slack から来たターンとみなし、`turn.complete` まで印を付けておく。この方法で判定できた。
- **ツールの拒否**: `tool.call` に `{ deny }` を返すと、`--permission-mode acceptEdits` でも Edit と Bash が止まった。対象ファイルは変わらず、拒否の理由はモデルに届いた。モデルは理由を読んで「Saqoosha の指示が要る」と答えた。Read は通った。
- **分類**: `prompt.submit` の中で `$.model.complete({ model: 'haiku' })` が動いた。「append して」という依頼を `CHANGE_REQUEST` と分類した。`input_hooks` の所要時間は 925 ms。分類結果を `context` に足すと、モデルはそれを読んで答えに反映した。
- CLI 2.1.287 で、`claude -p --plugin-dir` を使って測った。再現用のコードは spike の `register.ts`（下の「層 2」の形とほぼ同じ）。

## 構成

```
Slack thread ──event──▶ Saqoolaude Worker ──WebSocket──▶ canopyd ──▶ ShimProcess ──▶ CLI
     ▲                    (binding DO)        (canopyd から外向きに張る)    (phone-reply の注入経路)
     └──── 承認済みの返信 ◀── Saqoolaude ◀── 下書き ◀──────────────── ターン終了時の最後の発言
```

- **紐付け**: Canopy のペインメニューに「Slack スレッドに接続…」を置き、スレッドの permalink を貼る。紐付けは canopyd が持ち、Worker の Durable Object に `thread_ts → (Mac, session id, 質問できる人)` として登録する。紐付けは Canopy 側からしか作れない。
- **紐付けできないセッション**: SSH remote のセッションは紐付け対象外。shim が GUI にあり、mod も届かないため。
- **転送**: canopyd から Worker の DO へ WebSocket を張る。Pager と同じ形なので、Tailscale の内側に入口を開けなくて済む。認証には Saqoolaude MCP の固定キーを使う。読むのは 1Password のマウントから。
- **受信の条件**: 本文に `<@Saqoolaude>` を含むメッセージだけを拾う。bot 自身のメッセージは無視する。
- **注入**: Worker は、前回の質問以降のスレッドの発言を `conversations.replies` で取り、次の形にまとめる。
  ```
  [canopy:slack] <質問者の名前>からの質問
  <スレッドの差分>
  <質問>
  ```
  注入には control protocol の `send_message` に `slackAsker` を付けて使い、`wait_turn` と `latest_reply` で答えを受け取る。印は daemon が付ける。経路は電話の返信と同じなので、キューイングや、権限待ちと AskUserQuestion 中の拒否は、既存の門番がそのまま効く。門番が効かない可能性のあるセッションは `slack_refused` で拒否する。対象は、SSH remote のセッション、canopy-bridge がまだ報告していないセッション、bypass モードのセッション。
- **返信**: ターンが終わったら、最後の assistant の発言を下書きにする。Saqoolaude から Saqoosha への DM で送る。DM に ✅ のリアクションが付いたらスレッドに投稿し、❌ なら破棄する。`reaction_added` は購読済み。

## ガードレール

### 層 1：受信した質問の分類（canopy-bridge mod、`prompt.submit`）

- 印の付いたプロンプトを Haiku で 4 種類に分類する。質問、変更依頼、情報の持ち出し、指示の注入の疑い。
- 結果は `context` に `[filter] …` として足す。モデルだけが読む。
- 同じ結果を下書きの DM にも載せる。
- 分類に失敗したり時間切れになったりしたら `unknown` と書く。それでもターンは止めない。止めるのは層 2 の役目。

### 層 2：ツール呼び出しの門番（canopy-bridge mod、`tool.call`）

- Slack から来たターンの間、次のルールで判定する。
  - **通す**: Read / Grep / Glob のうち、セッションの cwd の中を対象にするもの。パスは `/bin/realpath` で symlink を解決してから判定する。認証情報らしい名前（`.env*`、`*.pem`、`id_*` など）は、cwd の中でも拒否する。Grep の `glob` 引数も同じ名前の規則で判定する。
  - **Haiku に判定させる**: cwd の外を対象にする Read / Grep / Glob。質問の本文とツールの入力を渡して「この質問に答えるのに必要な読み取りか」を判定させる。時間切れと分類不能は拒否として扱う。
  - **必ず拒否する**: 上の 2 つ以外のツールすべて。Bash、Edit、Write、NotebookEdit、MCP、WebFetch、Agent など。
- **Bash は LLM に判定させない**。シェルは外へデータを送れるので、層 3 の下書き承認を素通りする。そして LLM の判定は、Slack の本文で言いくるめられる。
- 残る穴：cwd 全体を対象にした Grep は、認証情報のファイルの中身にも当たりうる。読み取った内容が外に出る道は下書きしかないので、層 3 で止める。
- 拒否するときは理由を `deny` に書く。モデルはその理由を読んで、答え方を変える。
- 承認は一切しない。層 2 にできるのは、拒否することと、理由を伝えることだけ。
- 注入を拒否する条件：セッションが `bypassPermissions` のときは、Slack からの注入を受け付けない（Worker に拒否を返し、Saqoosha に DM する）。
- 印の扱い：印は Canopy が付けるもので、Slack の本文から外すことはできない。Saqoosha が手で `[canopy:slack]` と書いても、制限が増えるだけで害は無い。

### 層 3：下書きの承認

- Saqoosha が ✅ を付けるまで、スレッドには何も出ない。層 1 と層 2 をすり抜けた情報漏れは、ここで止まる。
- 自動投稿への切り替えは、紐付けごとの設定として後で足す（範囲外）。

### 質問できる人

- 紐付けた直後は Saqoosha だけ。ほかの人は、最初の質問のときに Saqoosha に DM で「〇〇さんが質問。✅ で許可」と聞く。✅ ならその人を紐付けの allowlist に足して、保留していた質問を流す。
- 紐付けのときに人を選ばせないのは、Canopy からは Slack の人の一覧が見えないため。

### 質問者に見えるもの

- 受け取った質問に Saqoolaude が 👀 を付ける。投稿されたら ✅、見送り・オフライン・拒否なら ❌ に替える（`reactions:write`）。
- セッションに渡す質問者の名前は `users.info` で引く（`users:read`）。どちらのスコープも 2026-10-22 に足した。

## 決めたこと

- 判定の印は本文の先頭に置く（`[canopy:slack]`）。webview のトランスクリプトにも見えるが、出どころが見えるのはむしろ望ましい。
- 門番は既存の canopy-bridge mod に足す。新しい mod は作らない。daemon が持つセッションには、すべて読み込まれているため。
- Slack のターンの最中に Saqoosha が打ったプロンプトは、そのターンに合流するので、制限を受ける。安全側に倒れるので、このまま受け入れる。

## 作る前に実機で確かめること

- Slack のターン中に起動したサブエージェントのツール呼び出しにも、層 2 の印が効くか。spike では main loop しか測っていない。
- Saqoolaude を `C089F5P7R9P` に `/invite` できるか。共有チャンネルなら、委託先のメッセージイベントが届くかも確かめる。

## 範囲外（findings）

- 紐付けごとの自動投稿モード。
- DM の中での下書きの編集（v1 は ✅ と ❌ だけ）。
- チャンネル単位の紐付け。
- 層 2 の判定ルールを、紐付けごとに設定できるようにすること。
