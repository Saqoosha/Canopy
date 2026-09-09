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

| 症状 | 読むのは誰か | 案 B で直るか |
|---|---|---|
| transcript が描画されない | extension | 直る |
| `@`-mention のファイル一覧が空 | extension（`workspace.fs` / `findFiles`） | 直る |
| Continue session が効かなかった | extension | 直る（既に別途対処済み） |
| `open_file` が読めない | **`ShimProcess`**（`handleOpenFile`） | **直らない** |
| 背景タスクの hourglass が残る | **`ShimProcess`**（`jsonlPath`） | **直らない** |

**「読むのは誰か」の列が、この表の要**で、症状の見た目では分類できない。
extension が読むものは extension ごと remote へ移るので local になる。
`ShimProcess` が読むものは移らない —— **`ShimProcess` は Swift 側で local に残る**
のがこの設計の前提だから。`handleOpenFile` は local の `workingDirectory` と
`FileManager` でパスを解決し、背景タスクの reconcile も `jsonlPath` を local で
stat する。どちらも remote のファイルには届かない。

初稿はこの列を持たず、5 行とも「remote にある」とだけ書いて全部直ることにしていた。
**下 2 行は直らない。** 境界を上げて得られるのは 3 行であって 5 行ではない。

peer name の chip が出ない件を、初稿ではここに 6 行目として書いていた。**削除した。**
peer messaging はマシンローカルで、CLAUDE.md が
*"a remote session is not a peer and correctly shows no name … Check a record
before reopening this."* と明記している。限界ではなく正しい挙動で、
実際 studio の実測でも chip は出ていない。

4 行目は既に塞いである。`RemoteSessionHistory` が SSH 越しに header を streaming で
読む。**つまり「穴を 1 個ずつ SSH RPC で塞ぐ」やり方の実装コストは既知**で、
あのファイル 1 本ぶん。

## herdr の置き方

herdr は境界を **client と server の間**に置く。`herdr machine add workbox` は
remote に herdr 本体を入れ、そこで server を起動し、local の client が SSH で
attach する。pane は remote の実ターミナル。だから remote 固有の機能差が
**原理的に存在しない**。sidebar に Local と並ぶのは、集約しているのが
client だけだから。

再接続もマシンごとに独立で、切れている間はキャッシュを dim 表示にする。
「同じに扱える」の正体は魔法ではなく、**ランタイムを各マシンに複製したこと**。

## Canopy への写像 —— 境界候補 3 つ

現在の境界（CLI spawn）を含めて、上から順に。

### 案 A —— 境界据え置き、穴の個別 RPC 化

Next Steps の Phase 2 がこれ。`workspace.fs` / `findFiles` / `open_file` を
SSH RPC に差し替える。

- 効く: `@`-mention、`open_file`
- 効かない: transcript 描画。あれは extension.js が local disk を前提にする層が
  もっと深く、RPC 1 本では届かない
- **`open_file` は案 A だけが直せる、という非対称がある。** 読むのが `ShimProcess`
  なので、案 A はそこを RPC に差し替えればよく、案 B は `ShimProcess` を local に
  残すぶん届かない。案 B に寄せても、この 1 個は案 A 側の手当てが要る
- コスト: 穴の数だけ。1 個の相場は `RemoteSessionHistory` 1 本ぶん
- リスク: 低い。既存の経路を壊さない

### 案 B —— shim の remote 配置

```swift
proc.executableURL = URL(fileURLWithPath: nodeInfo.path)   // 今
proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")  // 案 B
proc.arguments = [host, "node", remoteShimPath, "--extension-path", …]
```

**NDJSON パイプがそのまま SSH channel になる。** ShimProcess から下が丸ごと
remote に移るので、**上の表の「extension が読む」3 行が同時に消える**。
`~/.claude/projects` も CLI spawn も `workspace.fs` も、全部 remote 側で local として
解決する。**下 2 行は消えない** —— `open_file` と hourglass を読むのは `ShimProcess`
で、それは local に残る。

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
   `ExtensionUpdater` は local の 1 本しか知らない。**現に食い違っている** ——
   local が extension 2.1.263、studio が 2.1.266。実測ではこの組み合わせで動いたが、
   **そろえているものは何も無い**し、どこまで離れると壊れるかは未測定
2. **remote に CC extension と node ≥ 18 が要る（studio で充足を確認）。**
   herdr が remote に herdr を入れるのと同型で、herdr はそこを
   「approval-based setup」で処理している。ただし *Canopy が入っている* マシンでは
   前提が最初から満たされる —— studio は Canopy.app・CLI 2.1.266・Canopy 管理の
   extension 2.1.266 を持ち、shim もアプリバンドルに揃っている。**配布が要るのは
   Canopy を入れていない remote だけ**で、これは当初の見積もりより狭い。
   ただし probe は `/Applications/Canopy.app` を決め打ちするので、
   `~/Applications` に置いた Canopy は「入っていない」と報告される
3. **auth は刺さる。** ここは当初「remote に macOS Keychain が無いから」と書き、
   次に「SSH セッションが keychain を解錠できないから」と書き、次に
   「経路は変わらない」と棄却した。**最後の棄却が誤り**で、実機がそれを覆した。
   刺さるのは事実で、機序は SSH セッションが login keychain を解錠できないこと。
   詳細と、この項が結論を 3 回変えた経緯は「オンデバイス実測」節に書いた。
   出荷形での解き方は「出荷形の設計 §1」——
   注入をやめ、remote の CLI に `claude auth status --json` で聞く
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
`patchAuthIfNeeded` の `init_response` 分岐にある注入 1 本で立っており、それは Swift 側・パイプの
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

auth（3）はこの表から降りた —— 解決したからではなく、**設計の中心に昇格した**ため。
「出荷形の設計 §1」を見よ。

## 出荷形の設計

スパイクは「動く」ことだけを示した。ここから先は、スパイクが**逃げた**ところを
どう本気で解くか。7 点あり、1 番が設計の中心で、残りは作業に近い。

### 1. auth —— 注入の廃止と remote CLI への問い合わせ

**スパイクは嘘をついている。** `update_state` に **ローカルの** Keychain から
authStatus を注入するので、webview は「ローカルのアカウントで認証済み」と表示する
一方、実際の API 呼び出しは remote の `~/.claude/.credentials.json` を使う。
2 台が別アカウントなら、UI は動いていない方のアカウントを表示する。
`/login` が死ぬのは既知だと書いたが、より悪いのはこちらで、静かに間違う。

**remote の CLI は自分の認証状態を知っていて、SSH 越しに答えられる。** 実測（studio、
keychain がロックされた SSH セッション、`exit=0`）:

```
claude auth status --json
{ "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
  "email": "…", "orgId": "…", "orgName": "…", "subscriptionType": "max" }
```

webview が期待する形は `KeychainAuth.readAuthStatus()` が組み立てている
`{ authMethod, email, subscriptionType }` の 3 つだけなので、対応はほぼ 1 対 1。
正規化が要るのは `authMethod` の綴りひとつ（CLI は `claude.ai`、webview は
`claudeai`）。**そして `email` は Keychain 経路に無く、Canopy は今 `NSNull()` を
渡している** —— remote 経路の方が情報が多い、という珍しい向き。

だから出荷形は「注入をうまくやる」ではなく **注入をやめる**。remote セッションの
authStatus は remote の CLI から作る。これで 3 つ同時に片付く: 表示が事実になる、
`/login` を殺す理由が消える、そして「remote でログインし直す」が
**表現できる操作**になる（いまは概念ごと存在しない）。

未解決: `loggedIn: false` の remote をどう見せるか。ローカルにフォールバックしては
いけない —— それがまさにスパイクの嘘。remote 固有のログイン導線が要る。

### 2. パス解決 —— 非同期化と auth との 1 往復統合

`spikeRemotePaths` は main actor を同期 SSH でブロックする。上の auth 問い合わせも
SSH なので、**1 回の `ssh bash -s` でパスと auth を一緒に返す**のが素直。
セッション spawn の前に非同期で走らせ、結果をホストごとにキャッシュする。
キャッシュの無効化条件は「shim の spawn に失敗したとき」——
remote の Canopy 入れ替えを検出する手段はそれしかない。

### 3. 純粋関数の probe による pin

`spikeHostIsWellFormed`、`spikeSSHArguments`、そして上の authStatus マッピング。
いまは `--` を消しても host 検証を消しても suite が緑のまま。
この repo の floor はアサーションを数えるだけで、それが何かを守っている証明には
ならない —— 変異させて赤くなることを確認する。

### 4. model / effort —— 未解決、選択肢 2 つ

wrapper が消えると `CANOPY_REMOTE_MODEL` → `--model` の経路も消える。
(a) remote の `~/.claude/settings.json` を書く（**共有ファイルを触る**ので、
ローカル側が同じ理由で避けた手）。(b) remote 側にも `claudeProcessWrapper` を置き、
model/effort だけを足す最小の wrapper にする（`workspace.js` の `envOverrides` が
そのまま使える）。b の方が既存の仕組みに乗るが、**wrapper を消す話と矛盾する**ので、
決めるには「wrapper が何のために残るのか」を先に決める必要がある。

### 5. Canopy 未導入の remote —— v1 では対象外

明示的なエラーで止める。herdr はここを「approval-based setup」で解いており、
それが最終形。node と extension と shim の 3 つを配る話になるので、別の仕事。

### 6. バージョン skew —— 検出のみ、強制なし

webview は**ローカルの** extension、shim は remote の extension を実行する。
2.1.263 対 2.1.266 では動いた。壊れる幅は未測定なので、まずは**両方のバージョンを
ログと status bar に出す**。食い違いで拒否するのは、壊れ方を 1 つでも観測してから。

### 7. 2 経路 —— 同時削除の回避

`ssh-claude-wrapper.sh`、`CANOPY_REMOTE_*`、`RemoteSessionHistory`、
`index.js` の fs/spawn パッチは、この設計が完成すると**全部不要**になる。
ただし同じ変更で消さない: 設定で新旧を切り替えられる状態を一度作り、
新経路が実地で持つことを確認してから消す。**削除は別 PR。**

## レビューで出た未修正（挙動を足す変更なので提案に留めた）

8 本のレビュアーを回した。コメントと doc の**偽の主張は全部消した**し、既存 helper に
寄せられるものは寄せた。以下は**実行時の挙動を足す**修正で、スパイクの段階で
入れると「守りの分岐が増えて、壊れていないときに発火する」側に倒れるので、
提案として残す。重い順。

1. **ssh が spawn 後に死ぬと、ペインが無言で消える。** `start()` は ssh が起動できた
   時点で `true` を返す。存在しない host も、鍵拒否も、未登録 host key も、起動自体は
   成功して 255 で即死する。`activeSessionId` はまだ nil なので `handleProcessExit` は
   crash 側に落ち、ペインが閉じる —— issue #193 の症状そのもので、**#194 の
   `lastFatalError` が繋がっていない**。ssh の stderr は `info` なので数分で消える。
   最小の直しは「spike の失敗を全部 `boundSession?.lastFatalError` に載せる」1 点で、
   これだけで下の 2・3・4 が同時に可視化される
2. **再接続が終わらない。** `shimProcessDidDisconnect` が毎回 `reconnectAttempt` を 0 に
   戻し、`doReconnect` は `start()` が true を返した時点で `.connected` を宣言する。
   スパイクではそれは「ssh が実行可能だった」以上の意味を持たないので、
   ssh 起動 → 10 秒で死ぬ → カウンタ 0 → 3 秒待つ、が無限に続く。
   **この経路は今まで死にコードだった**（Phase 3.1 の既知欠陥どおり node が生き残るので
   `terminationHandler` が発火しなかった）。**スパイクがそれを主経路に昇格させた**ので、
   潜在バグが一緒に出荷される
3. **カスタム API の送信先が remote に届かない。** `ANTHROPIC_BASE_URL` /
   `ANTHROPIC_AUTH_TOKEN` は local の ssh プロセスに設定され、ssh は環境を転送しない。
   wrapper 経路は明示的に転送している。結果、**ユーザが選んでいない endpoint に会話が
   送られる**。ログも UI 差分も無い。「動いているときにも見えない」ので、
   この一覧でいちばん質が悪い。直すなら転送ではなく**起動前に拒否**すべき ——
   local の proxy を指す `ANTHROPIC_BASE_URL` を remote に転送すると、
   remote の localhost を指してしまう
4. **probe が ssh の stderr を捨て、全部の失敗が 1 つの誤ったメッセージになる。**
   `Host key verification failed`、`Permission denied (publickey)`、名前解決失敗、
   到達不能 —— 全部が "Is Canopy installed there?" になる。probe 自身は
   exit 3 / 4 で「extension が無い」「shim が無い」を区別して**いる**のに、
   Swift 側が捨てている
5. **probe に hard deadline が無く、失敗をキャッシュしない。** `ConnectTimeout` は TCP
   connect しか覆わないので、banner / 鍵交換で止まる host や、詰まる `ProxyCommand` は
   素通り。しかも成功しかキャッシュしないため、**壊れた host は spawn ごとに毎回
   ブロックを払う** —— 3 ペインの復元なら 3 回連続でアプリ全体が固まる
6. **キャッシュに無効化が無い。** `extensionPath` は extension 更新のたびに動くので、
   remote が自動更新した瞬間からそのプロセスの以後のセッションが全部落ちる
7. **spike なのに local の node / shim / extension / wrapper が必須。** どれも spike では
   使わないのに、無いと `start()` が false を返す。しかも文言が誤診を招く
   （"Install it in VSCode first." / "wrapper script not found."）
8. **remote のプロセス回収が効かない。** `stop()` の `collectDescendants` が見るのは
   local の ssh の子で、remote の node と CLI には届かない。通常は stdin close で
   remote の shim が自ら終わるが、蓋を閉じた half-open のような切れ方では
   remote が生き残りうる。ローカルからは観測できない

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
  スパイクが足した 2 箇所は `--` で塞ぎ、検証は
  **既存の `RemoteSessionHistory.isSpawnableHost` を呼ぶ**形にした（初稿は独自の
  文字集合検証を書いていたが、それは `isSpawnableHost` の doc が
  「厳しくすると正当な host を弾く」と明示的に退けている手で、実際
  `fe80::1%en0` を弾いた。削除した）。
  **残る露出は初稿の記述より狭い** —— `RemoteSessionHistory` は `--` こそ無いが
  `latestSession` が `isSpawnableHost` で弾いており、無防備なのは
  `RemoteDirectoryBrowser.swift:216` と `ssh-claude-wrapper.sh` の 2 行。
  host はランチャーの入力欄・`SSHHostStore`・restore snapshot から来るので権限境界は
  越えない（書ける相手はすでにこのユーザとして任意コマンドを実行できる）。
  実害より footgun の話。直すなら入口で 1 回検証する形にすべきで、
  その入口は既に `isSpawnableHost` として存在する

- 永続化（案 C）。要求が出ていない
- 複数 remote の集約 sidebar。herdr の machine list 相当。Canopy の sidebar は
  今 1 台ぶんしか概念を持たない
- 切断中の dim 表示。herdr がやっている、キャッシュを残して薄くする挙動。
  `ConnectionOverlayView` は全面オーバーレイなので、思想が違う
