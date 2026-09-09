# SSH remote の境界の置き場所 — herdr 方式の当てはめ

2026-09-09。設計メモであって計画ではない。実装の承認は取っていない。

## 現状の境界

```
WKWebView ─postMessage─ ShimProcess.swift ─stdin/stdout NDJSON─ node
                                                                 └ extension.js
                                                                    └ spawn ─→ ssh-claude-wrapper.sh ─→ ssh host claude
```

remote に出ているのは **CLI の spawn だけ**。WKWebView も shim も extension.js も
この Mac で動く。`ShimProcess.start()` は `Process()` に
`executableURL = nodeInfo.path`、引数 `[shimPath, --extension-path, --cwd,
--settings-path …]`、stdin/stdout/stderr の 3 本のパイプ。remote 化は
`env["CANOPY_SSH_HOST"]` 等 6 個の環境変数と 1 本のラッパースクリプトで表現されている。

## 制限の出どころ

「Remaining Limitations」に並んでいる症状は、別々の欠陥ではない。全部
**境界が CLI spawn にあること**の帰結で、原因は 1 行で言える —— *extension.js が
local で走り、それが読みたいファイルは remote にある*。

| 症状 | 読みたいもの | 実際の所在 |
|---|---|---|
| transcript が描画されない | セッション JSONL | remote |
| `@`-mention のファイル一覧が空 | `workspace.fs` / `findFiles` | local を見る |
| `open_file` が読めない | 対象ファイル | remote |
| peer name の chip が出ない | `~/.claude/sessions/<pid>.json` | remote（かつ socket も remote） |
| 背景タスクの hourglass が残る | 完了マーカーの JSONL scan | remote |
| Continue session が効かなかった | 直近セッションの header | remote |

最後の 1 行だけは既に塞いである。`RemoteSessionHistory` が SSH 越しに header を
streaming で読む。**つまり「穴を 1 個ずつ SSH RPC で塞ぐ」やり方の実装コストは
既知**で、あのファイル 1 本ぶん。残りは 5 個。

## herdr の置き方

herdr は境界を **client と server の間**に置く。`herdr machine add workbox` は
remote に herdr 本体を入れ、そこで server を起動し、local の client が SSH で
attach する。pane は remote の実ターミナル。だから remote 固有の機能差が
**原理的に存在しない**。sidebar に Local と並ぶのは、集約しているのが
client だけだから。

再接続もマシンごとに独立で、切れている間はキャッシュを dim 表示にする。
「同じに扱える」の正体は魔法ではなく、**ランタイムを各マシンに複製したこと**。

## Canopy に写すと境界候補は 3 つ

現在の境界（CLI spawn）を含めて、上から順に。

### 案 A — 境界は据え置き、穴を個別 RPC で塞ぐ

Next Steps の Phase 2 がこれ。`workspace.fs` / `findFiles` / `open_file` を
SSH RPC に差し替える。

- 効く: `@`-mention、`open_file`
- 効かない: transcript 描画。あれは extension.js が local disk を前提にする層が
  もっと深く、RPC 1 本では届かない。peer name も届かない（socket が remote）
- コスト: 穴の数だけ。1 個の相場は `RemoteSessionHistory` 1 本ぶん
- リスク: 低い。既存の経路を壊さない

### 案 B — shim を remote に置く

```swift
proc.executableURL = URL(fileURLWithPath: nodeInfo.path)   // 今
proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")  // 案 B
proc.arguments = [host, "node", remoteShimPath, "--extension-path", …]
```

**NDJSON パイプがそのまま SSH channel になる。** ShimProcess から下が丸ごと
remote に移るので、上の表の 6 行が同時に消える。`~/.claude/projects` も
CLI spawn も `workspace.fs` も peer socket も、全部 remote 側で local として解決する。

消えるものが多い。`ssh-claude-wrapper.sh` とその env 転送・`--resume` 追記・
`--model`/`--effort` フラグ化、`vscode-shim/index.js` の `fs.realpathSync` パッチと
`child_process.spawn` の cwd 書き換え、`CANOPY_REMOTE_*` 6 変数 —— **remote 経路の
特別扱いがほぼ全部**、境界の下に沈んで消える。

詰まりどころ。**2 と 3 は 2026-09-09 に mbp で実測した**（下の「実測結果」節）。
残る 1 / 4 / 5 / 6 / 7 は構造から読んだ推論のままで、まだ測っていない。

1. **webview asset は local に残る。** `index.js` / `index.css` は local extension から
   `file://` で読み込まれる（`WebViewContainer` の entry HTML）。WKWebView は remote の
   `file://` を読めないので、これは動かせない。shim は remote の extension.js を実行する。
   結果、**extension のコピーが 2 つになり、そのバージョン整合が新しい制約**になる。
   `ExtensionUpdater` は local の 1 本しか知らない。今日この 2 台は偶然そろっている
   （両方 Canopy 2.28.1 / extension 2.1.263）が、**そろえているものは何も無い**。
   片方だけ更新されたときに何が起きるかは未測定
2. **remote に CC extension と node ≥ 18 が要る（実測: mbp では既に揃っている）。**
   herdr が remote に herdr を入れるのと同型で、herdr はそこを
   「approval-based setup」で処理している。ただし *Canopy が入っている* マシンでは
   前提が最初から満たされる —— mbp は Canopy.app 2.28.1・Canopy 管理の extension
   2.1.263・node v24.11.1 を持っており、shim もアプリバンドルの
   `Contents/Resources/vscode-shim/` に 12 モジュール揃っている。**配布が要るのは
   Canopy を入れていない remote だけ**で、これは当初の見積もりより狭い
3. **auth の経路は変わらない（実測で棄却）。** ここは当初「remote に macOS Keychain が
   無いから刺さる」と書き、次に「SSH セッションが login keychain を解錠できないから
   刺さる」と書いた。**どちらも違う。** local で同じ probe を走らせたら、
   `Keychain read failed, trying file fallback` → `No authentication found` が
   **一字一句同じに出た**。`init_response` と `update_state` の `state` から
   `authStatus` キーが欠けているのも local と remote で同一。
   つまり拡張の AuthManager は **local でも認証を持っていない**。Canopy が動くのは
   `ShimProcess.swift:2753` の注入が *唯一の* auth 経路だからで、その注入は
   Swift 側・パイプの local 側で起きる。案 B でも ShimProcess は local に残るので、
   **この経路は丸ごと無傷**。remote の CLI は自分の `~/.claude/.credentials.json`
   （mbp に実在、mode 0600）を読むので、CLI 側も無傷。
   詳細と、この項が 2 回間違った理由は「実測結果」節に書いた
4. **`--settings-path` は local のパス。** `CanopySettings.shared.filePath` を渡している。
   remote 側で何を読ませるかは未決。remote の `~/.claude/settings.json` を
   直接書く形にすると、共有ファイルを触ることになる
5. **パイプの性質が変わる。** `availableData` は今ローカルパイプのチャンク。SSH 越しでは
   切れ方が変わる。stderr の undecodable-chunk 問題と、`process exited with code` による
   CLI 終了検出がその上に乗っている。ここは**実測が必須**
6. **Phase 3.1 の既知欠陥が副作用で解ける可能性がある。** 今は SSH が死んでも node shim が
   生き残るので `terminationHandler` が発火せず overlay が出ない。案 B では shim 自体が
   ssh プロセスなので、死ねば発火する。これは推論であって確認していない
7. **レイテンシは増えないと読める。** トークンストリームは今も SSH を渡っている。渡る場所が
   変わるだけ。ただし `get_session` の replay など、今 local で完結しているフレームが
   SSH に乗る。フレーム数は増える。要測定

### 案 C — herdr 型 daemon

remote に headless Canopy を常駐させ、local は client に徹する。

- 得: remote が自律する。lid を閉じても継続。複数 remote の集約 sidebar
- 損: Canopy の本体は WKWebView。headless 側に何を残すのかが自明でない。
  shim だけを残すなら**それは案 B そのもの**で、増える価値は persistence だけ
- 判定: 案 B は案 C の 1 段手前だが、案 C の主たる利得（永続化）を持たない。
  C が欲しくなるのは「閉じても走り続けてほしい」という要求が来たとき。まだ来ていない

## 実測結果（2026-09-09、mbp）

判断を分ける問いは 1 つだった —— *`ssh host node <shim>` が NDJSON を素通しできるか*。
**通った。** GUI もビルドも scp も要らず、mbp に既にあるものだけで走った。

```bash
{ printf '%s\n' '{"type":"webview_ready"}'
  sleep 2
  printf '%s\n' '{"type":"webview_message","message":{"type":"init"}}'
  sleep 10
} | ssh -T mbp 'HOME=$(mktemp -d) exec node \
    "/Applications/Canopy.app/Contents/Resources/vscode-shim/index.js" \
    --extension-path "…/Canopy/extensions/anthropic.claude-code-2.1.263-darwin-arm64" \
    --cwd "/Users/hiko" --settings-path "…/Canopy/settings.json"'
```

`ssh exit=0`、stdout に NDJSON 4 行、stderr 14 行。読み取れたこと:

- **activation が通る。** `MCP Server running on port 15004 (localhost only)` まで到達。
  CLAUDE.md の shim A/B レシピが「壊れていない」と定義する到達点そのもの
- **双方向が成立する。** local から流した `{"type":"init"}` が remote 側のログに
  `Received message from webview: {"type":"init"}` として現れ、`{"type":"ready"}` と
  `webview_message` 2 本が返ってきた
- **中身は本物の extension フレーム。** 封筒は CLAUDE.md が記録している
  `{type:"from-extension", message:{…}}` のまま、`session_states_update`（sessions/
  openSessionIds/unreadSessionKeys/liveElsewhereSessions を持つ）と
  `visibility_changed` が届いた。空の handshake ではない
- **scratch `HOME` は効いている。** lock は
  `/var/folders/…/tmp.Vbe1HXEdjf/.claude/ide/15004.lock` に落ちた。付けなければ
  remote の実ストレージを触る
- **拡張は未認証で立ち上がる。** `Keychain read failed, trying file fallback` →
  `No authentication found`。これを最初 remote 固有の欠陥と読んだ。**間違いだった**

### auth ——「測った 2 つを因果でつないだ」失敗

最初の実験で `No authentication found` を見た。次に SSH セッションの keychain
到達性を測り、こう出た:

| | local (Mac Studio) | remote (mbp / SSH) |
|---|---|---|
| `security find …`（metadata） | exit 0 | exit 0 |
| `security find … -w`（値） | **exit 0** | **exit 36** |
| login keychain | `no-timeout` | `User interaction is not allowed.` |
| shim の `secrets.json` | 無い | 無い |

差が 1 点だけきれいに出たので、これが原因だと書いた。**対照群を取っていなかった。**

同じ init probe を local で走らせると、こうなる:

| フレーム | local | remote |
|---|---|---|
| `init_response.state.authStatus` | **キー不在** | **キー不在** |
| `update_state.state.authStatus` | **キー不在** | **キー不在** |
| stderr | `Keychain read failed` → `No authentication found` | 同一 |

**完全に同じ。** 拡張の AuthManager は local でも認証を持っていない
（`security` CLI は読めるので、AuthManager はその経路を使っていない）。
SSH の keychain 制約は実在するが、**観測した症状の原因ではない**。

結論の向きが逆になる。Canopy の auth は最初から
`ShimProcess.swift:2753` の注入 1 本で立っており、それは Swift 側・パイプの
local 側で起きる。**案 B は auth を何も変えない。** ぼくの実験が未認証だったのは
remote だからではなく、`ShimProcess` を通さず生の shim を叩いたからで、
注入する主体が居なかっただけ。

remote の CLI は `~/.claude/.credentials.json`（mbp に実在、1487 B / mode 0600）を
読む。keychain が解錠できなくてもこれは読めるので、今日の SSH remote が
動いている理由もこれで説明が付く。

一般化: **測定 X と測定 Y が揃っても、X が Y の原因だとは言えない。**
差が 1 点しか無いときほど確からしく見えるので、対照群を取るまで因果を書かない。

`Unknown message: [object Object]` も出たが、これは `{"type":"init"}` が本物の init
ペイロードではないため。**経路の話ではなく、こちらが投げた形の話**で、この実験の
問いには影響しない。

## オンデバイス実測（スパイク、2026-09-09）

> **この節の「remote」は remote ではない。** 使ったホスト `mbp` は **このマシン自身**
> だった。hostname も `IOPlatformUUID` も一致（`Saqooshas-MBP` /
> `C211808F-…`）、Tailscale の magic DNS が自分の名前を自分に解決していた。
> `ssh mbp` はループバック。
>
> だから下の結果のうち、**別マシンであることに依存する主張はすべて無効**。
> `~/.claude/projects` の 189 ファイルが「両機で一致」したのは同期ではなく同一
> ディレクトリだからで、対照で transcript が描画されたのも、peer name chip が
> 出たのも（peer messaging はマシンローカル）、「remote に Canopy が既にある」のも、
> 全部それで説明が付く。
>
> **生き残る主張**は SSH セッションに依存するもの —— shim が SSH channel 越しの
> NDJSON で動くこと、SSH セッションが login keychain を解錠できないこと
> （`security -w` が local exit 0 / SSH exit 36、同一マシンなので keychain も同一）、
> そのため webview がログイン画面に落ちること。auth の因果はむしろ強まる:
> マシンが同じでもセッションが SSH なら通らない。
>
> 本物の別マシンは `studio`（`Saqoosha-Mac-Studio`、Tailscale 100.72.162.115）。
> Canopy.app あり、CLI 2.1.266、Canopy 管理の extension **2.1.266** ——
> こちらの 2.1.263 と**食い違っている**ので、詰まりどころ 1 のバージョン skew は
> 仮定ではなく現状。測り直しはこのホストで行う。
>
> なぜ気づかなかったか: ホスト名を CLAUDE.md の例（"e.g. `mbp`"）から引き写し、
> **別マシンであることを一度も確認しなかった**。「対照を取れ」の一段手前に
> 「前提を確認しろ」がある。

`ShimProcess.start()` に `CANOPY_SPIKE_REMOTE_SHIM=1` で入る分岐を足し、Debug を
建てて mbp のセッションを開いた。GUI 操作は使わず、launch-restore snapshot を
`defaults write sh.saqoo.Canopy.debug canopy.sessionRestore.v1` に植えるルート。

**動いた部分。** `SPIKE: resolved remote Canopy on mbp` → `SPIKE: running shim on
mbp` → activation → `MCP Server running on port 48862`、lock は remote の**実
HOME**（`/Users/hiko/.claude/ide/48862.lock`）に落ちた。CLI も remote で起動し、
messaging socket（`/tmp/cc-socks/…`）まで作った。UI には **peer name chip
（`canopy-2e`）がサイドバー行とペインヘッダの両方に出た** —— 今日の SSH remote では
構造上ありえない表示で、境界を上げた効果がそのまま見えている。status bar も
`mbp` とブランチ名を出した。

**止まった部分 —— auth。** ペインはログイン画面（"How do you want to log in?"）。
`Injected Keychain authStatus into init_response` はログに出ており、注入自体は
発火している。それでもログイン画面が出るのは、`update_state` が
`authStatus ?? null` で戻すという既知の挙動と整合する。

**上の「auth の経路は変わらない」は、この実測で覆った。** 対照として同じビルド・
同じ snapshot・同じ `open` 起動でフラグだけ外すと、`Auth from Keychain: claudeai`
が成功し、shim の AuthManager も失敗ログを出さず、ログイン画面も出ない。差はフラグ
だけ。**スパイクが auth を壊している。**

なぜ前の節が「local も remote も同じ」と結論したかというと、あの local probe が
**GUI 起動ではなかった**から。Bash ツールから起動した shim と、SSH 越しの shim は
どちらも keychain に届かず、GUI 起動の Canopy 配下の shim だけが届く。つまり最初に
測った keychain の差（`-w` が exit 0 対 exit 36）は**やはり原因だった**。棄却したのが
誤りで、棄却の根拠にした対照が不適格だった。

同じ罠に 3 回はまっている。1 回目は隔離した scratch HOME を remote の性質と読み、
2 回目は不適格な対照で因果を棄却し、3 回目はその棄却を実機が覆した。**対照は
「片方だけ変える」では足りない。変えていないつもりの条件（起動経路）が
効いていないことまで確かめる必要がある。**

**まだ言えないこと。** 対照で transcript が描画されたが、
**それが remote のものだとは言えない**。
使った id（`fe7a0783…`）は local の同名 project フォルダにも実在する
ので、`RemoteSessionHistory` が警告している「同じパスが両機にあると local の会話が
replay される」状態に当たる可能性がある。スパイクがこの症状を直すかどうかは、
**local にコピーが無い id で測り直すまで未判定**。

次の一手は分かっている: spike 経路に限って `update_state` にも authStatus を注入する。
`ShimProcess` の該当箇所は「注入すると logout/re-login ができなくなる」と明記して
いるので、出荷経路に広げずスパイク限定にするのが条件。

## 本物の remote での実測（studio、2026-09-09）

`studio`（`Saqoosha-Mac-Studio`、Tailscale 100.72.162.115）で測り直した。別マシンで
あることは hostname と `IOPlatformUUID` の両方で確認済み。

**汚染を構造的に排除した試験台**を選んだ。resume 対象は
`/Users/hiko/repos/Work/Saqoolaude` のセッション —— **そのディレクトリも、その
エンコード済み project フォルダも、このマシンには存在しない**。だからペインに
描画されたものは remote から来たとしか説明が付かない。

**結果 —— ゴール到達。**

- **transcript が完全に描画された。** ツール呼び出しの中身まで含めて。表示された
  Bash コマンドは
  `cat /Users/hiko/.claude/projects/-Users-hiko-repos-Work-Saqoolaude/memory/MEMORY.md`
  で、そのパスはローカルに無い
- **ログイン画面が消えた。** spike 限定の `update_state` 注入が効いた。Canopy 側の
  `Auth from Keychain: claudeai` はローカルの GUI プロセスで成功しており、
  SSH セッション側が読めないぶんをこれが埋めている
- **入力欄が生きている**（`Opus 5 High` / `Manual`）。status bar は `studio`
- **peer name chip は出ない。これが正しい挙動。** peer messaging はマシンローカル
  なので、本物の remote セッションに名前は無い。`mbp` で出ていたチップは
  localhost の産物だったと確定した —— スパイクの成果ではない
- **バージョン skew が実地で動いた。** webview は**ローカルの** extension 2.1.263 を
  読み、shim は studio の **2.1.266** を実行している。詰まりどころ 1 が心配していた
  2 コピーの同居は、この組み合わせでは成立する。壊れる幅は未測定
- studio 固有の MCP サーバ（`blender`）が接続しており、CLI が向こうで走っている
  ことの傍証になっている

**まだ測っていない症状**: `@`-mention のファイル一覧、`open_file` / ContentViewer、
背景タスクの hourglass。いずれも GUI 入力が要るが、合成クリックは使わない
（下の findings 参照）。

## 推奨

**案 B。** 上の実測で最大の未知（パイプが SSH を渡れるか）が消え、案 A に落ちる
理由が無くなった。残りは既知の作業への分解になる。

次に測るべき順（重い順ではなく、**判明したら設計が変わる順**）:

1. **パイプの切れ方**（5）。`availableData` の chunk 境界が SSH 越しでどう変わるか。
   stderr の undecodable-chunk 問題と、`process exited with code` による CLI 終了検出が
   その上に乗っている。**残る最大の未知はここ**
2. **`terminationHandler`**（6）。Phase 3.1 が副作用で解けるかどうか
3. **バージョン skew**（1）。extension を片方だけ上げたときに何が壊れるか。
   今日はそろっているので、壊し方を作らないと測れない
4. **レイテンシとフレーム数**（7）。案 B の採否は変えないが、体感を決める

auth（3）はこの表から降りた。上の実測で、案 B が何も変えないことが分かったため。

## 保留（findings、この設計の外）

- **`system/init` はターンのときにしか来ない**（`canopy-21` の実測、commit 10134af）。
  Canopy を経路から外し、`/tmp` の fresh セッションに
  `claude -p --input-format stream-json --output-format stream-json --verbose
  --include-partial-messages` を当てて計測:
  stdin を 12 秒開けたまま黙っていると `system/hook_started` ×6 /
  `hook_response` ×5 / `hook_progress` だけで **init は来ない**。
  t=12.0 に 1 ターン書くと t=12.21（0.2 秒後）に `system/init`、続いて
  `system/status`、`stream_event` … と流れる。
  だから **init を待ってから最初のターンを送るコードは黙ってデッドロックする**。
  fresh でも resumed でも同じなので、resume 由来の癖ではなく構造。
  `cliResolvedModel` は init から書かれるため、**どのセッションでも最初の実ターンまで
  空**で、その間ずっと context meter の model 参照が外れる。これは既存の挙動で
  スパイクとは無関係。
  ここに置く理由は 1 つ —— shim を SSH 越しに動かして init が見えないとき、
  **transport のせいだと誤診する**筋があるから。`mbp` の罠と同じ形で、
  間違った説明の方が手近にある

- **pid で解決したウィンドウ id は「撮る」のは安全、「クリックする」のは安全でない。**
  `canopy-21` から届いた実測。`CGEvent` を `kCGHIDEventTap` に投げると、配送先は
  **スクリーン座標のその点で最前面にあるウィンドウ**で決まる。一方
  `screencapture -o -x -l <windowid>` は**オクルージョンを無視して**撮る。だから
  スクリーンショットは自分のチャット入力欄を写しているのに、その座標の実際の最前面は
  別ウィンドウ、ということが起きる。**`NSWorkspace.frontmostApplication` を pid と
  照合しても防げない** —— 照合は通り、イベントは覆っている側へ行った。実際に別
  セッションの入力欄へ文字が落ちた。入力を合成するなら
  `CGWindowListCopyWindowInfo`（前面→背面順）を歩いて、その点を含む最初のウィンドウが
  自分であることを確認する。しない方が安い。`reference_canopy_debug_build_as_ab_rig`
  の memory は「CGEvent クリック + screencapture で駆動」と書いており、**この罠を
  含んでいる**ので更新が要る

- **既存の ssh 呼び出しに `--` が無い。** `ssh` は先頭が `-` の引数をフラグとして
  読むので、host 文字列が `-oProxyCommand=…` だと接続前に任意コマンドが走る。
  スパイクが足した 2 箇所は `--` と `spikeHostIsWellFormed` で塞いだが、
  `RemoteSessionHistory.swift:343`、`RemoteDirectoryBrowser.swift:216`、
  `ssh-claude-wrapper.sh` の 2 行は同じ形のまま。host はランチャーの入力欄・
  `SSHHostStore`・restore snapshot から来るので権限境界は越えない（書ける相手は
  すでにこのユーザとして任意コマンドを実行できる）。実害より footgun の話で、
  直すなら 1 箇所ずつではなく入口で 1 回検証する形にすべき

- 永続化（案 C）。要求が出ていない
- 複数 remote の集約 sidebar。herdr の machine list 相当。Canopy の sidebar は
  今 1 台ぶんしか概念を持たない
- 切断中の dim 表示。herdr がやっている、キャッシュを残して薄くする挙動。
  `ConnectionOverlayView` は全面オーバーレイなので、思想が違う
