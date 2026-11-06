# フォルダを選ばずに始めて、過去のセッションを探し、必要ならプロジェクトへ移る

Saqoosha は前の作業を忘れて、セッションを開いて回り「どこまでやった？」と聞いている。探すためのセッションにもフォルダが要るので、いまは `~/.claude` を受付の代わりに使っている。

これを、フォルダなしで始めて聞くだけで済むようにする。答えのセッションはそのまま開ける。始めた話がプロジェクトの仕事になったら、会話ごとそのフォルダへ移れる。

## 実測したこと（2026-11-06）

### 使われ方（直近 60 日、自動実行を除く）

- 人間のセッションは mbp 468、studio 274。1 日の中央値はどちらも 5 セッション。2 時間以上あけて戻った回数は mbp 209、studio 265。
- `~/.claude` で始めたセッションは mbp 37、studio 49。使い方は 3 種類ある。
  - 探す：`where do we discuss about 業務委託基本契約書?`
  - 新しい仕事を始める：`Create new folder 大梁川渓谷 under repos/Personal`
  - プロジェクトがない用事：`timemachine backup failed...?`
- 自動 recap は 60 日で約 2,500 回生成されていた。本人は読んでいない。

### 検索

- 検索範囲で見つかるセッション数が大きく変わる（2 台の合計）。

  | 単語 | タイトル＋最初の発言 | ＋全発言 | ＋返答 |
  |---|---|---|---|
  | collision | 5 | 44 | 68 |
  | 契約 | 2 | 9 | 223 |
  | 見積 | 0 | 4 | 162 |

  本人が英語で書き、返答が日本語なので、日本語の語は返答にしか出ないことが多い。サイドバー検索はタイトルとプロジェクト名しか見ない。`list_sessions` の `query` は最初の発言までで、どちらもこの Mac だけが対象。
- 生ログへの `rg -l` は 2 回目以降 0.16〜0.31 秒、初回は約 1 秒。ログは mbp 7.5 GB、studio 13.5 GB。どれもファイルキャッシュが温まった値で、再起動直後は未測定。
- 一致の大半は本文ではない。`keychain` は mbp の人間のセッションで 579 件当たり、本文だけに絞ると 62 件。
- 本文への絞り込みまで含めた Python の試作は、珍しい単語で 0.34〜0.71 秒。`fdf r6 release` のように一致行が多いと、mbp 4.8 秒、studio 30 秒。
- 試作の絞り込みは、全行解析の結果の 84〜100% しか拾えなかった。原因は未確認。
- 過去に Claude に頼んだときは 51 秒と 56 秒で見つけた例がある。別の Mac を後回しにした例もある。`i lost session about releasing FDF CUP R6 tracks`（9/29）は 7 分探して「この Mac に残っていない」で終わった。
- 探す依頼をしたセッション自身が検索に当たる。上の 9/29 のセッションは `fdf r6 release` で 2 位に出た。

### 移動

- CLI 2.1.318 に制御リクエスト `set_cwd` がある。拡張機能が同梱する CLI も同じ版。stdin に次を書く。

  ```json
  {"type":"control_request","request_id":"…","request":{"subtype":"set_cwd","path":"<dir>"}}
  ```

  返事は `control_response.response.response` に入る。`{status:"ok",cwd,changed,transcript_relocated}`、`{status:"needs_trust",directory,trust_root?}`、`{status:"rejected",reason}` の 3 種類。`reason` は `busy`、`unsafe_path`、`not_found`、`not_a_directory`、`blocked_by_rule`。`needs_trust` には `trust_accepted:true` と `trusted_directory` を付けて送り直す。
- `set_cwd` は 0.17 秒で終わる。プロセスとセッション ID はそのままで、会話の記憶、移動先の `CLAUDE.md`、`pwd` が切り替わる。transcript は CLI が移し、`relocated` を記録する。
- `/cd` は TUI 専用で、stream-json では `/cd isn't available in this environment.` になる。
- Canopy のペインでは `set_cwd` だけでは足りない。次のターンは動くが、リロードすると `Loading...` で止まる。移動していないセッションのリロードは正常だった。
- `set_cwd` のあとに `moveToCheckout` と同じ手順で `origin` と `project` を差し替えて再起動すると、表示、履歴、記憶、`CLAUDE.md`、リロード、閉じて開き直す操作がすべて正常だった。再起動の 6 秒後には履歴が戻っていた。正確な時間は未測定。
- `result` の直後の `set_cwd` は `busy` で断られ、3 秒後は通った。
- 信頼済みのフォルダは少ない。最近のプロジェクトのうち mbp は 39 個中 4 個、studio は 40 個中 7 個。Canopy の起動経路では信頼の確認が出ないためだと思われる。`needs_trust` は例外ではなく、最初の移動ではほぼ毎回通る。

### 土台

- `CLAUDE_CODE_PLUGIN_DIRS` のプラグインに置いた skill は `<plugin>:<skill>` の名前で読まれる。本文の `${CLAUDE_SKILL_DIR}` と `${CLAUDE_SESSION_ID}` は解決される。Bash には `CLAUDE_CODE_SESSION_ID` が入っている。
- `settings.json` の `canopy.mirrorPeers` の値（`IP:port`）の IP に、`ssh -o BatchMode=yes` で両方向につながった。
- `open_session` で開いたセッションは一覧に `dormant` で出るだけで、ペインは開かない。daemon から GUI への通知は `session_state` と `upgrade_state` しかない。
- `scripts/canopyctl` はアプリに同梱されていない。

## 成功の条件

聞く場所は、手元の Mac の Launcher から始めたセッションだけ（Saqoosha）。

1. ⌘⇧N を押してすぐ、Launcher に質問を打てる。フォルダは選ばない。
2. 「あの件どこ？」に、両方の Mac を見たうえで、どの Mac、どのプロジェクト、いつ、どこで止まったかが返る。従来の 1〜7 分より短い。
3. 「開いて」で、そのセッションがペインに出る。別の Mac なら mirror ペインに出る。
4. 「VDGS に移動して」で、今の会話がそのフォルダで続く。

## やらないこと

- データベース、索引、本文のキャッシュ。生ログの `rg` で足りる（Saqoosha の指摘で取り下げた）。
- 全セッションの進捗一覧。欲しいのは特定の 1 件を探すこと。
- SSH remote と cloud セッションの検索。
- 別の Mac への移動。
- mirror で見ているセッションからの依頼への対応。Saqoosha はそこから頼まない。ホストから見ると mirror のセッションも普通のローカルセッションなので、判定もしない。頼まれた場合、開く先も確認画面もホストの Mac になる。
- worktree に入っているセッションの移動。
- `~/.claude` の既存セッションや memory の移行。
- スマホからの No folder 開始。

## 失敗とみなすこと

- 本人が確認していないフォルダを信頼済みにする。
- 見つかっていないのに候補を断定する。届かない Mac を「無かった」と報告する。
- 移動でターンの途中の作業や、送信済みで待っている入力を失う。
- ⌘N の今の動きが変わる。

## 決めたこと

Saqoosha が決めたのは、recap をやめること、DB を使わないこと、フォルダなしで始めて移動する形、別の Mac も検索して mirror ペインで開くこと。残りはこの文書で「判断」と書いた Claude の判断で、Saqoosha は設計書を書くことを承認した段階にある。

### Canopy Agent の形

専用のプロセスや画面は作らない。No folder のセッションに、同梱の skill を 2 つ足したものを Canopy Agent と呼ぶ（判断）。普通のセッションなので、続けて質問でき、どのセッションからでも skill を呼べる。

### No folder

CLI にはフォルダが必須なので、Canopy 専用の空フォルダ `~/Library/Application Support/Canopy/no-folder/` で起動する（判断）。Debug と Release で共有する。

- 新しいメニュー項目 `New Session Without Folder`（⌘⇧N）が、このフォルダを選んだ Launcher を開く。Launcher を通すのは、起動を待たずに打ち始められるから（判断）。
- Launcher のフォルダ選択の先頭にも `No folder` を足す。⌘N の動きは変えない。
- サイドバーとペインのプロジェクト名は `No folder` と出す。
- フォルダには Canopy が `CLAUDE.md` を置く。内容は 3 点。ここはプロジェクトではない。過去の話は `find-session` で探す。プロジェクトの仕事になったら移動を提案する。

### find-session skill

検索スクリプトと `SKILL.md` で作る。保存は一切しない。

スクリプトの役割：

- `search TERM...` は、単語を全部含むセッションを探す。`--any` は、どれか 1 つを含むセッションを探す。
- `--all` のとき、`canopy.mirrorPeers` の各 Mac へ `ssh -o BatchMode=yes` で同じスクリプトを流す。結果には machine id を付ける。つながらない Mac は `error` 付きの行で返す。
- `tail SESSION_ID` は、そのセッションの最後の数ターンを返す。別の Mac のものも同じ経路で読む。
- 本文の条件：`type` が `user` か `assistant`、`isSidechain`、`isMeta`、`isSynthetic` でない、`entrypoint` が `sdk-` で始まらない。`user` はさらに、`<`、`[Request`、`[Canopy keep-alive]` で始まるものと `Caveat:` を除く。
- `rg` には `-L` を付ける。プロジェクトフォルダのシンボリックリンクを追うためで、付けないと取りこぼす。同じファイルの二重計上は実パスで防ぐ。
- 呼び出したセッション自身は `--exclude` で外す。
- 1 行の結果は、machine、セッション ID、タイトル、cwd、最後の発言の日付、単語ごとの一致数、最初と最後の発言、本文の抜粋。
- 1 台あたりの時間に上限を設ける。超えたら途中までの結果であることを明示して返す。

`SKILL.md` の手順：

1. 質問を、英語と日本語の両方のキーワードにする。`r6` のような短い語より、珍しい語を選ぶ。
2. 最初から `--all` で探す。
3. 上位の候補を `tail` で読み、関係を判断する。過去に同じ件を探しただけのセッションは候補から外す。
4. どの Mac、どのプロジェクト、いつ、どこで止まったかを答える。
5. 見つからないときは「見つからない」と言い、近い候補と、探せなかった Mac を分けて書く。

Slack の URL が渡されたら、メッセージ ID（`p…`）と `thread_ts` の両方を `--any` で探す。studio ではリンクを貼って戻る使い方が多い。

### 開く

新しい verb `show_session` を足す。引数はセッション ID と、別の Mac なら machine id。

- ローカルのソケットからだけ受ける。
- daemon は、購読中の GUI へ新しい通知を送る。GUI がいなければ失敗を返す。
- GUI は、すでにあるセッションならそのペインを前に出す。閉じていれば開く。別の Mac なら `openRemoteRecent` で mirror ペインにする。向こうで動いているセッションには、この関数の中で参加する。
- 新しいペインに開く（判断）。質問した No folder のペインに答えが残るから。上限に達したときは既存の扱いに従う。

### 移動

新しい verb `move_session` と skill `move-session` を足す。

verb の条件：

- ローカルのソケットからだけ受ける。**信頼に関する引数は持たない**（2026-11-06 のセキュリティレビューの指摘）。
- SSH remote と、worktree の中のセッションは理由を付けて断る。
- 移動先は、存在するフォルダの絶対パス。

手順：

1. verb は移動の予約だけをして、`queued` を返す。skill は自分のターンの中で呼ぶので、その場では動けない。
2. `ShimProcess.moveToCheckoutWhenQuiet` と同じく、`restartLosesWork` が空になるのを待つ。
3. shim が CLI の stdin へ `set_cwd` を書く。`busy` なら間隔をあけて再試行し、上限を超えたら諦める。
4. `needs_trust` なら GUI が確認画面を出す。承認されたときだけ `trust_accepted` を付けて送り直す。CLI が覚えるので、確認はフォルダごとに 1 回で済む。
5. `ok` なら `moveToCheckout` と同じく `origin` と `project` を差し替えて再起動する。
6. 失敗は、ターンがもう終わっているので、ペインのエラー表示で知らせる。

信頼の確認は常に出す（判断）。Canopy で開いたことがあるフォルダを自動で承認する案は採らない。承認は「本人が承認した」という CLI への申告で、Canopy が代わりにしてはいけない。GUI がいないときと、確認が時間切れになったときは移動しない。

同じ Mac のプログラムはソケットに触れるので、GUI になりすませば確認を通れる。これはソケット全体の信頼範囲（`docs/CONTROL_PROTOCOL.md`）の中の話として受け入れる。TCP からは届かない。

GUI の追従は、daemon のセッション行に足す移動回数で判定する（判断）。`followsCheckoutMove` は変えない。この関数は、別の場所へ追従しないことを既存のテストで守っているから。「同じパスの別表記でペインを再起動しない」という性質も、これで保たれる。

入力欄の打ちかけの文章は、再起動で消える（判断）。コードを読むと webview ごと作り直すので消える。実機では未確認。移動はターンが終わった数秒後に動くので、その間に打ち始めると失う。本人が頼んだ直後の短い時間なので、最初の版では復元しない。

### 同梱

skill とスクリプトは `Resources/canopy-bridge/` に置く（判断）。verb とアプリの版が必ず揃い、両方の Mac へ Canopy の更新で届くから。

- `installBridgeMod()` のファイル一覧に足す。
- `canopyctl` も同じ経路で同梱する。`show` と `move` のサブコマンドを足す。
- shim が `CANOPY_CONTROL_SOCK` をセッションの環境へ入れる。Debug のセッションが Release の daemon を操作しないため。

## 確かめること（実機）

過去の実際の依頼で確かめる。正解は、そのセッションのその後のログからわかる。

- `where do we discuss about 業務委託基本契約書?`（studio、11/5）
- `where are we talking about this thread?` と Slack の URL（studio、11/6）
- `i lost the previous door session`（studio、9/28）
- `i lost the session which is organizing google drive shard folders of taiwan team`（studio、10/5）
- `i lost session about releasing FDF CUP R6 tracks`（mbp、9/29）。ログに残っていないので、断定しないことが正解。

このほかに確かめること：

- mbp からも studio からも、もう片方のセッションが見つかり、mirror ペインで開く。
- 相手の Mac が落ちているとき「届かない」と答える。
- 実際の Git リポジトリへ移動して、ブランチ表示と `@` のファイル検索が新しいフォルダを指す。
- 初めてのフォルダで確認画面が出て、断ると移動しない。
- ターン中に頼むと、終わってから移動する。

## 作る順番

どれも単独で出せる。`find-session` だけでも、一番の困りごとは解ける。

1. `find-session`（`~/.claude` のセッションからでも使える）
2. `show_session`
3. No folder
4. `move_session`

recap の削除は別の PR にする。過去の transcript には `/recap` が約 2,500 回残っているので、履歴とタイトルの読み取りで除外している処理は消さない。

## builder に任せること

- スクリプトの言語と内部構成、絞り込みの順序。ただし上の本文の条件と、84〜100% の漏れの解消は必須。
- 再試行の間隔と上限、時間切れの長さ。
- 通知フレームと verb の細部、確認画面の見た目。
- `CLAUDE.md` の文面。
- テストの置き方。CI の下限（`EXPECTED_TESTS`、`EXPECTED_ASSERTIONS`）の更新は必要。

## 試作の扱い

worktree `session-history-search` に、コミットしていない試作がある。`set_cwd` を shim から CLI へ届ける部分は `Resources/vscode-shim/index.js` の `spikeSetCwd` が出発点になる。`SpikeDriver.swift` と、`followsCheckoutMove` への変更は捨てる。

## 範囲外（findings）

- 検索を `ssh` ではなく mirror の接続で行う案。パスワードで認可でき、ssh の承認待ちが起きない。ただし daemon の改修が要る。
- 信頼済みのフォルダが少ないこと自体。Canopy の起動を信頼の確認につなげるかは別の話。
- 別の Mac での No folder 開始。
- `~/.claude` にある memory の扱い。
