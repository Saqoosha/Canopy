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

ミラー client を `MirrorSink`（WKWebView か TCP 接続）に広げ、`MirrorServer`（NDJSON、最初の行が `{"type":"attach","sessionId"}`）と、Debug メニュー「Attach to Remote Session…」（`host:port/sessionId`）を足した。`CANOPY_MIRROR_LISTEN=<port>` は loopback に、`<host>:<port>` はその address にだけ bind する。

- **localhost で成立。** Debug を 2 プロセス立て、B の attach 窓から送った turn が A の CLI で走り、A のペインと B の窓の両方に描かれた
- attach の id は `OpenSession.resumeId`。`-p` で作った transcript は extension が resume できず fresh になるので、A の id は植えた id から変わる。`attach refused` のログに open sessions を列挙するようにした
- `generate_session_title` は `channelId` を envelope ではなく `request` の中に持つ。envelope だけ書き換えると `Channel not found: <mirror channel>` で title 生成が落ちる
- **studio → MBP、Tailscale 越しに handshake 成立。** 最初は 8770 だけ timeout（port 22 は通る）で、MBP の Application Firewall が Debug ビルドの着信を止めていた。Allow 後、studio の Python client の `attach` が通り（server log の `attached`）、`init` に cache の `init_response` が 4 KB 返った。この時点の listener は全 interface に bind していた
- **MBP → studio、GUI で cross-machine 成立。** Debug を studio に rsync して `open -n --env CANOPY_MIRROR_LISTEN=8770`（ssh 越しの `open` で GUI セッションに立つ。env も届く）、MBP の Debug の Attach 窓から `100.72.162.115:8770/<id>` で繋いだ。窓から送った prompt が studio の CLI で走り、studio の transcript に user 1 件 + assistant 1 件が書かれ、返事が MBP の窓に描かれた。extension は両機とも 2.1.270 で、版ずれの測定はできていない
- studio の 1 回目の起動では listener が立たなかった（env はプロセスに届いていた）。2 回目は立った。再現条件は未特定
- `init_response` には Keychain から注入した `authStatus` が入る。attach できる者は auth 状態を受け取る。port の認証は出荷形で必須で、Tailscale の interface に bind するだけでは足りない
- `open -n -g`（背面起動）だと窓が作られず `.task` も走らない。`open -n` は前面に出るので、テスト中のキー入力が Debug 側に落ちる（Cmd+W で一度セッションを閉じられた）

## 残り（findings）

- abort で生成された `deny` を shim で捨てる。今は extension が捨てているだけで、順序次第では本物の答えより先に届きうる
- `generate_session_title` を各 webview が投げるので、title 生成が webview の数だけ走る
- live channel が無いときにミラーが送ると、ミラー自身の launch が live になる。この経路は設計どおりだが未測定
- primary の webview が消えた（ペインを閉じた）あとのミラーの扱い。今は `webView` が nil でもミラーには配り続ける
- transport の出荷形：Tailscale の interface にだけ bind し、DEBUG と env var の外に出す。attach 先の id は resumeId より安定な何か（sidebar からのコピー）が要る
- phone：iPhone は Tailscale 上にあるので relay を通さず同じ port に直結できる。残るのは webview asset（`index.js` / `index.css`）の版合わせと 390pt の見た目
