# 長いジョブの終了時刻をサイドバーと電話に出す

例：rt4090 で IG 全体版の LOD 生成（793 チャンク）を流している。サイドバーの行に `10:40 · 41%` が出ていて、電話にも同じ時刻が出る。Saqoosha が `eta` と聞かなくて済む。

## 目的

Saqoosha は長いジョブ（rt4090 の 3DGS 学習、Blender／独自レンダー、ZTMY-TV の処理など）が**何時に終わるか**を知りたい。今は `eta` と聞くたびに、セッションの Claude が ssh と grep で進みを数え、速さを出して時刻にしている（2026-10-22〜11-21 のログで約 10 回。答え方は毎回同じで、`done/total` を取るコマンド 1 本と経過時間からの計算）。`/loop` の 30 分ごとの報告もこれを model に繰り返させている。

この計算を canopyd に移し、結果をサイドバーの行と電話にいつも出す。

## 目標

- ジョブを持つセッションの行に、終了予定の時刻と割合をいつも出す
- 電話（Canopy-Mobile）にも同じ情報を出す。サイドバーの `attentionLine` も一緒に電話へ送る
- ジョブが止まったら、その行を Needs you に移し、電話に 1 回だけ push する
- 進みの計測に model を使わない

## 目標外（findings）

- MacroPad への表示。`attentionLine` を MacroPad へ流すことも含む
- background task の出力から `N/M` を自動で拾うこと（下の「作り方」の案 2）。登録忘れを補う機能として後から足せる
- 工程の連鎖（抽出 → 学習 → エンコード）。v1 は 1 セッションにジョブ 1 本
- miyagawa の Agent Board のようなタスクの Timeline

## 失敗の条件

動いていても、次のどれかが起きたら失敗：

- 間違った時刻を自信ありげに出す。測れないときは測れないと出す
- 止まっていないジョブを「停止」と出し、push で起こす
- 計測のために model のターンやトークンが増える

## 制約

- セッションは canopyd が持つ。GUI は daemon の `session_state` を写すだけ（`ControlProtocol.swift`、`docs/CONTROL_PROTOCOL.md`）
- 呼び出し元のセッションは `--session-id "${CLAUDE_SESSION_ID}"` で名乗る。`move-session` skill と同じ形で、daemon は `ControlProtocol.sessionRefs` / `requestedSession`（`ControlSession.swift`）で引く。`CANOPY_PANE` はペインの番号で、並べ替えで変わるので使わない
- `CANOPY_CONTROL_SOCK` は SSH remote のセッションには export されない（`ShimProcess.swift`、`remoteHost == nil` のときだけ）。SSH remote のセッションは daemon の roster にも載っていないので、v1 の対象外
- unread（緑）は GUI だけが持つ集合で、`isThinking` が true から false に変わったときに付く（`MacroPadController`、`SessionStore`）。daemon は unread を付けられない
- `SessionActivity.of` はサイドバー、MacroPad の LED、Dock バッジ、`session_state.state`、roster の `state` に使われている。`.error` は「シムが落ちた」の意味で、asking より上の優先順位。error の行は `attentionLine` を出さない（`SidebarRow.swift`）
- roster は会話の中身を運ばない、という決まりがある（`RosterSnapshot.swift` の冒頭、`docs/superpowers/specs/2026-09-03-canopy-mobile-design.md`）
- セッションの Claude は rt4090 に 1Password の SSH agent で入っている（`~/.claude/settings.json` の `SSH_AUTH_SOCK`）。canopyd の LaunchAgent の環境にはこの変数が無い
- bridge の skill と hook は `ShimProcess.bridgeModFiles` に載せないと配られない。logic probe の「同梱ファイルが全部載っているか」の検査が抜けを見つける
- 電話への snapshot は毎回まるごと送る（`RosterPublisher`）。relay（Canopy-Mobile の Worker、`machine.ts` の `applySnapshot`）は JSON をそのまま保存して返すので、フィールドを足しても Worker の変更は要らない。電話の `PaneRow` は Codable で、知らないキーは無視する
- push の種類は Worker の `NotifyBody.kind`（今は `"completed" | "asking"`、別型で `"battery"`）。新しい種類を足すなら Worker の変更と deploy が要る
- テストは in-app の logic probe。CI の `EXPECTED_ASSERTIONS`（今は 2633）を、増やした数だけ上げる

## 作り方

進みの数をどこから取るかで 3 案を比べ、**案 1** に決めた（2026-11-21、Saqoosha）。

| 案 | 中身 | 決め手 |
|---|---|---|
| **1. 登録した probe を canopyd が流す** | Claude がジョブを始めるときに「`N/M` を出すコマンド」と実行先を登録し、canopyd が数分おきに流す | rt4090 で `nohup` した学習、Vast、ローカルのレンダーを同じ形で扱える。本命の用途を拾えるのはこれだけ |
| 2. background task の出力を読む | canopyd が数えている background task の出力から `N/M` を正規表現で拾う | 登録は要らないが、ssh の先で `nohup` したジョブの出力は手元に無い。誤検出もある |
| 3. セッションが状態ファイルを書く | Claude が確かめるたびにファイルへ書き、canopyd は読むだけ | 書くたびに model が動く。目的に反する |

案 1 は Claude が登録を忘れると何も出ないので、skill と hook で使い方を教える（下の「Claude への指示」）。

## 構成

```
Claude ──canopyctl job watch──▶ canopyd ──probe (sh / ssh)──▶ ジョブのログやファイル
                                   │
                                   ├─ session_state.job ──▶ GUI のサイドバー
                                   └─ roster snapshot ─────▶ relay ──▶ 電話
                                        └─ 停止・完了 ──/notify──▶ APNs
```

### 登録

```
canopyctl job watch --session-id "${CLAUDE_SESSION_ID}" --label "IG LOD" \
  --probe 'grep -oE "\[[0-9]+/793\]" ~/woven-city/logs/ig_lod.log | tail -1' \
  [--host rt4090] [--interval 150] [--stall-minutes N]
canopyctl job list --session-id "${CLAUDE_SESSION_ID}"   # eta と聞かれたらこれを読む
canopyctl job clear --session-id "${CLAUDE_SESSION_ID}"
```

- control verb は `job_watch` / `job_list` / `job_clear`。セッションは `--session-id` で決まる
- 1 セッションにジョブは 1 本。もう一度登録すると置き換える
- **probe の約束**：出力の最後の `(\d+)\s*/\s*(\d+)` を `done/total` とみなす。`--total` を渡したときは、出力の最後の整数を `done` とみなす（`ls | wc -l` の形。`grep -c` は 0 件で exit 1 になり、読み取りの失敗になるので使わない）
- `--host` があれば `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> <probe>` で流す。1 回の実行は 30 秒で打ち切る
- **ssh の認証**（ぼくの判断）：probe の ssh には、セッションの Claude と同じ `SSH_AUTH_SOCK`（1Password の SSH agent）を渡す。この値は Claude Code が `~/.claude/settings.json` の `env` から自分のプロセスに読み込んでいるもので、canopyd の環境には無い。だから canopyd も probe を流すたびに同じファイルの `env.SSH_AUTH_SOCK` を読む（無ければ自分の環境の値）。1Password が承認を求める元のアプリは、セッションの ssh と同じ Canopy.app になる。ControlMaster（`ControlPersist`）で接続を使い回し、承認の回数を減らす。専用の鍵は作らない（2026-08-03 に、平文の予備の鍵を意図して消したため）。認証に失敗したら「不明」にして、ホバーに「ssh の認証に失敗」と出す
- 登録は daemon の状態として保存し、canopyd が再起動しても残す。セッションが閉じたら消す

### 計測

- 既定は 150 秒ごと。登録の直後に 1 回流す
- **終了時刻**：速さ（Δdone / Δt）は直近 15 分の標本から出す。ただし窓には `done` が変わった点が少なくとも 2 つ入るように、足りなければ窓を広げる（1 単位に 15 分以上かかるジョブのため）。`now + (total − done) / 速さ`。`done` が変わった点が 2 つそろうまでは「計測中」で、時刻は出さない
- **停止**（ぼくの判断）：`done` が `max(15 分, 1 単位にかかった時間の中央値 × 3)` 変わらない。`--stall-minutes` を渡せばそれを使う。1 エポックに 20 分かかる学習を 15 分で「停止」にしないため
- **probe の失敗**：3 回続けて失敗したら「不明」にする。停止とは別に扱い、push もしない
- **完了**：`done >= total`。リングを消す。GUI は、ジョブの状態が `done` に変わったことを unread を付ける新しいきっかけとして扱う（今の `isThinking` の切り替わりと並べる）。電話は `job.state == "done"` を見て完了の印を出す。電話に push を 1 回送る

### 行の状態（ぼくの判断：`SessionActivity` は変えない）

停止を既存の `.error` に入れると、MacroPad の LED が赤くなり、電話では「シムが落ちた」と同じ意味になり、error の行は `attentionLine` を隠す。だから `SessionActivity` には手を入れず、サイドバーと電話の表示の段で上書きする。

- ジョブがあってセッション自身が idle なら、リングと点は background（藍）の色で描く。ジョブが走っているのに灰色だと、止まって見えるため
- 停止したら、リングと点を error と同じ赤で描き、行を Needs you の段に移す。2 行目は「680/1077 で止まっている」
- セッションが asking や error なら、その色と段のまま（停止より上）。リングは描く
- Dock バッジと MacroPad は今のまま（停止を数えない）。MacroPad は目標外のため

## サイドバーの見た目（決定、2026-11-21）

mockup で B2「点をリングにする」を選んだ。

```
● Needs you                      2
  ◉ Kenja 記事一覧の改修          4m      ← 橙の点。今のまま
     Bash: wrangler deploy …
  ◔ h7_final レンダー           停止      ← 赤のリング（63%）
     680/1077 で止まっている       15m
● Working                        2
  ◔ IG 全体版の LOD 生成         10:40    ← 藍のリング（41%）
     WovenCity-3DGS               41%
  ◕ 屋外マウンドの学習           13:15    ← 青緑のリング。model も作業中
```

- 点は今の `ActivityDot`（色も呼吸も今のまま）。その周りに同じ色で進捗の弧を描く。色に新しい意味は持たせない（`SessionActivity.dotRGB`）
- 右端は経過時間の代わりに、上段が終了時刻（`HH:mm`、日をまたぐなら `明日 1:20`）、下段が割合。停止なら `停止` と止まっている分数。計測中なら `計測中`、不明なら `—`
- ホバーで `IG LOD 328/793 · あと 55 分` を出す
- ジョブの無い行は今と同じ
- 行ごとに色を変える案は採らなかった。色とセッションの対応を覚える必要が出るため。進捗を行の内側（点の周り）に収めれば、どの行のものか迷わない

## 電話

- **roster の決まりを変える**（2026-11-21、Saqoosha が承認）：roster は会話の中身を運ばない、という決まりをやめ、`attentionLine` を載せる。`RosterSnapshot.swift` の冒頭のコメントと `docs/superpowers/specs/2026-09-03-canopy-mobile-design.md` の該当箇所を同じ変更で書き直す。電話へのイベントの流れには assistant の本文がもう乗っているので、新しく外に出る情報はほぼない
- `RosterSnapshot.Pane` に省略可能なフィールドを 2 つ足す：`attentionLine` と `job`（`label`、`done`、`total`、`etaAt`（unix 秒、無ければ null）、`state`（`measuring` / `running` / `stalled` / `unknown` / `done`））
- 終了時刻は Mac が unix 秒で送り、電話が自分の時計で表示する
- canopyd が計測するたびに値が変わるので、snapshot も送り直される（150 秒に 1 回程度）
- 電話の行も Mac と同じ形：状態色のリング、右端に時刻と割合、止まったら赤
- push：停止と完了で 1 回ずつ。Worker の `NotifyBody.kind` に `job_stalled` と `job_done` を足す（Worker の deploy が要る）

## Claude への指示

- **bridge skill** `skills/job-watch/SKILL.md`：10 分を超えそうなジョブを始めたら登録すること、probe の書き方（例：ログの `[328/793]`、`ls … | wc -l` と `--total`）、`eta` と聞かれたら ssh せずに `canopyctl job list` を読むこと、SSH remote のセッションでは使えないこと。`bridgeModFiles` に載せる
- **hook の念押し**（`hooks/register.ts`）：Bash の呼び出しに長いジョブの起動の形（`run_in_background`、`nohup`、`setsid`、`tmux new -d`、`screen -dm`、末尾が `&` の `ssh`）があり、そのセッションにジョブが登録されていなければ、「進捗を出すなら job-watch」と一言返す。同じセッションでは 30 分に 1 回まで

## テスト

logic probe に足す：probe 出力の解釈（`N/M`、`--total`、数字なし）、終了時刻の計算（直近 15 分の窓、標本不足、進みゼロ）、停止と不明の判定、行の状態の優先順位、`session_state` と roster の往復（新フィールドあり・なし）、`bridgeModFiles` の掲載。足した数だけ `EXPECTED_ASSERTIONS` を上げる。電話側は Canopy-Mobile の既存のテストの形に合わせる。

## 作る人に任せること

- 標本を持つ数と、日をまたぐ表示の細部
- ssh の ControlMaster を使い回すかどうか
- 登録を保存する場所と形式（daemon の既存の状態ファイルに合わせる）
- 電話の行のレイアウトの細部（Mac の形から外れない範囲で）
- hook が長いジョブとみなす形の正規表現
