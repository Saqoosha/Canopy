# 同一セッションへの多重接続 — ミラー窓スパイク

2026-09-14。設計メモとスパイクの実測記録。出荷判断は取っていない。

## 問い

tmux の attach のように、1 つの Claude Code セッションに local と remote の両方から同時に繋げるか。

## 答え

繋がる。多重化する点は **shim（`ShimProcess`）** で、JSONL でも CLI でもない。CLI は tmux の server、WKWebView は client。extension は webview が 1 つだと信じているので、shim が N 個の webview を 1 つに見せる。

transport の前に、Debug ビルドの **ミラー窓**（`MirrorSessionWindow`、Cmd+Shift+M）で同じ `ShimProcess` に 2 本目の WKWebView を繋ぎ、プロトコル側だけをローカルで測った。ペインに載せなかったのは、Canopy のペインが 1 セッション 1 ペインを前提にしていて、その不変条件の書き換えがプロトコルより先に来るから。remote attach は「ミラー窓の webview が別マシンにある」だけで、ここで通ったコードがそのまま transport の下に沈む。

## shim が肩代わりするもの（全部実測で決まった）

| webview が送るもの | shim の扱い | 理由 |
|---|---|---|
| `init`（2 人目以降） | cached `init_response` で答え、extension に流さない | extension の `init` ハンドラは 2 回目の init を「client が reload した」と読み、**全チャンネルを閉じる**。ミラーの init から 10 ms で `Closing Claude on channel`、CLI は `launch_claude` が届く前に消えた |
| `launch_claude`（live channel あり） | 飲み込み、その webview の channel を live channel に対応付ける。合成 `system/status` をその webview にだけ返す | 流すと CLI がもう 1 本立つか、`Channel already exists` で拒否される |
| `launch_claude`（live channel なし） | 流す。それが live channel になる。primary / mirror どちらからでも | channel は `close_channel` で死ぬ。次に送った webview が再 launch する |
| `channelId` 付きの frame | その webview 固有の channel → live channel に書き換え | webview は自分の channel 以外の `io_message` を `Session not found` で捨てる |
| `request` | requestId と送り主を記録し、`response` はその webview にだけ返す | 全員に流すと他の webview が `No handler` を吐く。id は `Math.random().toString(36)` なので衝突しない |
| 拡張→webview の request への `response` | 他の全 webview に同じ requestId の `cancel_request` を流す | permission dialog は webview-local。片方で Yes しても他方の dialog は残る（実測） |

出口は逆向き：live channel を各 webview 固有の channel に書き戻して配る。

## 実測（Debug ビルド、extension 2.1.270、GUI 入力は CGEvent、遮蔽ガード付き）

- ミラーから送った turn が primary にも描かれ、primary から送った turn がミラーにも描かれる
- 後から開いたミラーは `get_session_request` の replay で過去の transcript を丸ごと描く
- permission dialog は両窓に出る。primary で Yes → ミラーの dialog が消え、コマンドが走り、結果が両窓に出る。ミラー側は abort で `deny` の response を自動生成し、extension が `No handler` で捨てた
- `allowFileAccessFromFileURLs` を落とすと真っ白で console にも何も出ない。ペインは [WebViewContainer.swift](../../../Sources/Canopy/WebViewContainer.swift) で立てている
- shim の stdout は `from-extension` で二重に包まれている。`patchAuthIfNeeded` と同じ unwrap をしないと `init_response` も `close_channel` も見えない（1 回踏んだ）

## transport（同日、続き）

ミラー client を `MirrorSink`（WKWebView か TCP 接続）に広げ、`MirrorServer`（NDJSON、最初の行が `{"type":"attach","sessionId"}`）と、Debug メニュー「Attach to Remote Session…」（`host:port/sessionId`）を足した。`CANOPY_MIRROR_LISTEN=<port>` は loopback に、`<IPv4>:<port>` はその address にだけ bind する。host 名は拒否する（NWListener は IP literal でない `requiredLocalEndpoint` を黙って無視し、全 interface の random port に bind する）。

- **localhost で成立。** Debug を 2 プロセス立て、B の attach 窓から送った turn が A の CLI で走り、A のペインと B の窓の両方に描かれた
- attach の id は `OpenSession.resumeId`。`-p` で作った transcript は extension が resume できず fresh になるので、A の id は植えた id から変わる。`attach refused` のログに open sessions を列挙するようにした
- `generate_session_title` は `channelId` を envelope ではなく `request` の中に持つ。envelope だけ書き換えると `Channel not found: <mirror channel>` で title 生成が落ちる
- **studio → MBP、Tailscale 越しに handshake 成立。** 最初は 8770 だけ timeout（port 22 は通る）で、MBP の Application Firewall が Debug ビルドの着信を止めていた。Allow 後、studio の Python client の `attach` が通り（server log の `attached`）、`init` に cache の `init_response` が 4 KB 返った。この時点の listener は全 interface に bind していた
- **MBP → studio、GUI で cross-machine 成立。** Debug を studio に rsync して `open -n --env CANOPY_MIRROR_LISTEN=8770`（ssh 越しの `open` で GUI セッションに立つ。env も届く）、MBP の Debug の Attach 窓から `100.72.162.115:8770/<id>` で繋いだ。窓から送った prompt が studio の CLI で走り、studio の transcript に user 1 件 + assistant 1 件が書かれ、返事が MBP の窓に描かれた。extension は両機とも 2.1.270 で、版ずれの測定はできていない
- studio の 1 回目の起動では listener が立たなかった（env はプロセスに届いていた）。2 回目は立った。再現条件は未特定
- `init_response` には Keychain から注入した `authStatus` が入る。attach できる者は auth 状態を受け取る。port の認証は出荷形で必須で、Tailscale の interface に bind するだけでは足りない
- `open -n -g`（背面起動）だと窓が作られず `.task` も走らない。`open -n` は前面に出るので、テスト中のキー入力が Debug 側に落ちる（Cmd+W で一度セッションを閉じられた）

## phone（同日、branch `mirror-mobile-attach` と Canopy-Mobile の worktree `mirror-attach`、未 commit）

phone は extension を持たない。attach 成功時に server が `attach_ok`（entry HTML と user script 7 本）を返し、asset は `asset_request` / `asset_response`（base64）で socket 越しに引く。entry HTML は `canopy-asset://ext/webview/index.{css,js}` を参照し、extension が返す asset URI は `/resources/clawd.svg` のような root 相対なので、同じ scheme の下で解決され、frame の中身を書き換える必要が無い。

- **server が返す asset は extension の `webview/` と `resources/` の下だけ。** `../extension.js`、`webview/../package.json`、`native-binary/claude` は拒否（実測）。`index.js` 5,223,326 B、`index.css` 415,265 B、`clawd.svg` は byte 一致
- **保留中の permission / AskUserQuestion の request は、遅れて launch した client に再送する。** dialog が出た後に開いた mirror 窓に同じ dialog が出て、そこで Yes するとコマンドが走り primary の dialog も消えた（実測）
- **iOS Simulator（iPhone 16 Pro、iOS 18.5）で往復成立。** Simulator は Mac と network を共有するので loopback の server に繋げる。Mac から送った turn が phone 幅の webview に描かれ、Simulator の composer で打った prompt が Mac の CLI で走って両方に描かれた
- **iOS は 16px 未満の入力欄に focus すると page を拡大し、composer が画面外に出る。** phone 側で viewport を `maximum-scale=1` に上書きする user script を足して止めた
- `log_event` が mirror の channel のまま extension に届き `Channel not found for logEvent` が出る。telemetry だけで、描画と操作には影響なし
- Simulator は `CGEventKeyboardSetUnicodeString` を keycode 0 として読む（`A` になる）。文字ごとの keycode で打つ必要がある
- **実機 iPhone Air（Tailscale 越し）で往復成立。** Mac の Debug を `CANOPY_MIRROR_LISTEN=<Tailscale IPv4>:8770` で起動し、Debug の Canopy-Mobile を `devicectl process launch --environment-variables '{"CANOPY_MIRROR_ATTACH":"<ip>:8770/<id>"}'` で起動した。phone で打った prompt が Mac の CLI で走り、phone から頼んだ Bash の permission dialog が phone に出て、phone で Yes を押すとコマンドが走り、結果が両方に描かれた
- Tailscale の macOS 版は、自機の Tailscale address への自分自身からの接続を折り返さない（timeout）。到達確認は別の機械（studio）から行う
- iPhone Mirroring 越しの入力は、テキストを `pbcopy` して Cmd+V で paste し、送信ボタンをタップする。Return は app に届かない

## `/clear` の実測（同日）

primary で「BANANA を覚えて」と送り、mirror 窓で `/clear` を打ち、primary で「覚えた単語は？」と聞いた。

- **typed の `/clear` は画面のずれを起こさない。** webview はそれを普通の prompt として共有の CLI に送り、CLI が会話をクリアする。両方の窓が同時に `/clear` だけの画面になり、primary の質問への返事は両方の窓で `UNKNOWN` だった
- **画面がずれるのは、webview が自分の channel を閉じて再起動するとき（`restartClaude`）だけ。** 呼ばれるのは plugin の追加・再読み込みの後と、再起動を要求する一部のコマンド画面。この経路は未測定
- webview の「新しい会話」は、host が `create_new_conversation` を送るか `openNewInTab` のときだけ動く。Canopy はどちらも使わない

## 出荷形（同日）

- **Canopy の Settings › Mobile に「Live mirror」。** 初期値は off。on にすると、この Mac の Tailscale IPv4（100.64.0.0/10）にだけ bind し、Tailscale が無ければ listen せず「Tailscale is not running on this Mac」と出す。Release でも動く（検証用の 2 つの窓は DEBUG のまま）。DEBUG に限り `CANOPY_MIRROR_LISTEN=<IPv4>` で bind 先を上書きできる
- **attach には password（token）が要る。** Canopy が 32 byte の乱数を Keychain（`sh.saqoo.Canopy.mirror`）に作り、定数時間で比較する。settings.json には書かない。Settings の「Copy Connection for iPhone」で `canopy-mirror://<ip>:<port>?token=…` を clipboard へ、「Reset Password」で作り直す
- **phone は Settings の「Paste Connection from Mac」だけ。** address を保存し、token を Keychain に入れる。拒否されると「The Mac rejected the password」と出す
- **実機で通した流れ（2026-09-14、iPhone Air）：** toggle off で listen しない → on で `Listening on 100.116.127.93:8770` → Copy → Universal Clipboard で phone の Paste（iOS の「ペーストを許可」が出る）→ 保存した password で attach → 往復 → Mac で Reset Password → 古い password の phone は拒否
- **普段使いの経路も実機で成立。** roster の行 → 会話画面の Live ボタン → 保存した password で attach し、それまでの会話が描かれた。phone が送る `resumeId` は Mac の session id と一致する。Mac に無い session を開くと「This session is not open on the Mac.」と出る
- Mac でコピーした直前に別の文字列を clipboard に入れると、Universal Clipboard はそちらを先に phone に届けることがある。phone の Paste が「Canopy の接続ではない」と言ったら、少し待って押し直せば通る
- settings.json は Release と共有なので、Debug で on にした `canopy.mirrorEnabled` は Release の次回起動にも効く。同じ port を取り合うと後から起動した方は bind できず、Settings に理由が出る

## 残り（findings）

- abort で生成された `deny` を shim で捨てる。今は extension が捨てているだけで、順序次第では本物の答えより先に届きうる
- `generate_session_title` を各 webview が投げるので、title 生成が webview の数だけ走る
- live channel が無いときにミラーが送ると、ミラー自身の launch が live になる。この経路は設計どおりだが未測定
- primary の webview が消えた（ペインを閉じた）あとのミラーの扱い。今は `webView` が nil でもミラーには配り続ける
- transport の出荷形：Tailscale の interface にだけ bind し、DEBUG と env var の外に出す。attach 先の id は resumeId より安定な何か（sidebar からのコピー）が要る
- phone：iPhone は Tailscale 上にあるので relay を通さず同じ port に直結できる。残るのは webview asset（`index.js` / `index.css`）の版合わせと 390pt の見た目
