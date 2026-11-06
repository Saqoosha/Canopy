# フォルダなしで始めて、探して、移動する 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launcher からフォルダを選ばずに聞き始め、過去のセッションを両方の Mac から探して開き、今の会話をプロジェクトへ移せるようにする。

**Architecture:** 専用のプロセスは作らない。Canopy の `canopy-bridge` プラグインに skill を 2 つ同梱し、検索は生ログへの `rg` で行う（保存なし）。開く操作と移動は daemon の verb にして、GUI へは新しい通知フレームで届ける。移動は CLI の `set_cwd` のあと、既存の `moveToCheckout` と同じ手順でセッションを再起動する。

**Tech Stack:** Swift 6 / macOS、Python 3（標準ライブラリのみ）、Node（vscode-shim とテスト）、ripgrep。

**Spec:** [docs/superpowers/specs/2026-11-06-no-folder-session-design.md](../specs/2026-11-06-no-folder-session-design.md)

## Global Constraints

- 4 つの Part は別々の PR にする。Part A だけでも出せる。順番は A、B、C、D。各 PR は最新の `main` の上に作る。
- **コミット、push、PR は Saqoosha の許可のあとにする**（`CLAUDE.md`）。実行を始めるときに一度確認する。
- 検索はデータベース、索引、本文のキャッシュを使わない。
- 信頼の引数を control の verb に持たせない。`trust_accepted` を送るのは、GUI の確認画面で本人が承認したときだけ。
- 新しい verb はローカルのソケットからだけ受ける（`guard isLocal else { return fail(request, "local clients only") }`）。
- ⌘N の動きを変えない。
- recap の削除はこの計画に含めない。別の PR にする。
- `ShimProcess` の新しいラッチは `resetActivityState()` で必ず消す（`docs/notes/source-files.md`）。
- `test/` のファイルは `ci.yml` の 3 つの一覧のどれかに入れる。件数の下限は、実際の数を読んで書く。
- `ShimProcess` のクロージャは `@MainActor` の罠がある（`CLAUDE.md` の Traps）。`DispatchQueue.main` 以外から呼ばれるものは `nonisolated` にする。

## Review Focus

1. 一致が多すぎる語で検索したとき：止まらず、途中までの結果と `truncated: true` を返す。Task 1 のテスト。
2. 別の Mac に届かないとき：その Mac だけ `error` になり、手元の結果は返る。Task 1 のテスト。
3. 引用符、空白、日本語を含む語を `ssh` 先へ渡すとき：fish と zsh のどちらでも語が変わらない。Task 1 のテスト。
4. 同じフォルダへの移動（`changed: false`）：再起動しない。Task 8 のテスト。
5. 確認が必要なのに GUI がいないとき：移動せず、理由を知らせる。Task 9 のテスト。

---

## 準備

### Task 0: 試作を片付けて最新の main に載せる

**Files:** なし（作業ツリーの整理）

- [ ] **Step 1: 試作の差分を保存する**

Run: `git diff > "$SCRATCHPAD/spike.patch"`、`cp Sources/Canopy/SpikeDriver.swift "$SCRATCHPAD/"`
Expected: `spike.patch` が 0 バイトでない。画面の確認で `SpikeDriver` を使うときは、コミットせずに一時的に当てる。

- [ ] **Step 2: 試作を消す**

Run: `git restore Resources/vscode-shim/index.js Sources/Canopy/ControlSession.swift Sources/Canopy/SessionStore.swift Sources/Canopy/ShimProcess.swift`、`rm Sources/Canopy/SpikeDriver.swift`
Expected: `git status --short` に `docs/superpowers/` の 2 ファイルだけが残る。

- [ ] **Step 3: main に追いつく**

Run: `git fetch origin main`、`git merge --ff-only origin/main`
Expected: `git log -1 --oneline` が `origin/main` と同じ。このブランチにコミットはまだないので fast-forward で済む。

---

## Part A: 探す

### Task 1: 検索スクリプト

**Files:**
- Create: `Resources/canopy-bridge/skills/find-session/find_sessions.py`
- Create: `test/find-sessions.test.js`
- Modify: `.github/workflows/ci.yml`（`CI_TEST_FILES` に追加、shim の job に `sudo apt-get install -y ripgrep`、`EXPECTED_TESTS` を実数に）

**Interfaces:**
- Produces（Task 2 と Task 10 が使う）：

```
find_sessions.py search [--all] [--any] [--exclude ID]... [--limit N] [--timeout SEC] TERM...
find_sessions.py tail SESSION_ID [--machine MACHINE_ID] [--turns N]
```

`search` の標準出力は JSON 1 個。既定は `--limit 15`、`--timeout 40`、`tail` は `--turns 3`。

```json
{"machines":[
  {"machine":"local","host":"Saqooshas-MBP","ok":true,"truncated":false,
   "sessions":[{"sessionId":"…","title":"…","cwd":"…","lastActive":"2026-11-05",
                "hits":{"契約":12},"firstPrompt":"…","lastPrompt":"…",
                "snippets":[{"role":"assistant","text":"…"}]}]},
  {"machine":"DFE1CB09-…","host":"","ok":false,"error":"…"}
]}
```

- [ ] **Step 1: 失敗するテストを書く**

`test/find-sessions.test.js` は `node:test` で書く。`HOME` を一時フォルダに差し替えて、`python3 find_sessions.py` を起動する。transcript は実物の形で作る：`{"type":"user","entrypoint":"claude-vscode","cwd":…,"sessionId":…,"timestamp":…,"message":{"role":"user","content":"…"}}`、`{"type":"assistant","timestamp":…,"message":{"content":[{"type":"text","text":"…"}]}}`。

テストと確かめること：

| テスト名 | 確かめること |
|---|---|
| `finds a word that only appears in a reply` | 返答にだけある `契約` のセッションが返る |
| `ignores hook text and tool results` | `attachment` 行と `tool_result` にだけある語は 0 件 |
| `ignores sidechain, meta and synthetic records` | `isSidechain`、`isMeta`、`isSynthetic` の行は数えない |
| `ignores keep-alive prompts` | `[Canopy keep-alive]` で始まる発言は `lastPrompt` にならない |
| `leaves out automated sessions` | `entrypoint: "sdk-py"` のセッションは返らない |
| `excludes the asking session` | `--exclude` の ID は返らない |
| `requires every term unless --any` | 2 語の AND と `--any` の OR |
| `matches a short ascii term as a word` | `r6` は `abcr6def` に当たらず、`R6 track` に当たる |
| `matches japanese inside a longer word` | `契約` は `契約書` に当たる |
| `counts a symlinked project once` | シンボリックリンクのプロジェクトも見つかり、二重に数えない |
| `reports truncated when out of time` | `--timeout 0` で `ok: true`、`truncated: true`、途中で止まらず終了する |
| `reports an unreachable peer without losing local results` | `settings.json` に peer を置き、偽の ssh が 255 で終わると、`ok: false` の行と手元の結果が両方返る |
| `sends terms to a peer unchanged` | 語 `it's 契約` が、偽の ssh の先で同じ文字列に戻る |
| `tail returns the last turns` | `--turns 2` で最後の 2 ターンの発言と返答 |

偽の ssh は環境変数 `FIND_SESSIONS_SSH` で差し替える。実物と同じく、最後の引数群をリモートのシェルが解釈する形で受け取るスクリプトにする。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `node --test test/find-sessions.test.js`
Expected: FAIL（スクリプトがない）

- [ ] **Step 3: `find_sessions.py` を実装する**

標準ライブラリだけで書く。`rg` は `PATH`、`/opt/homebrew/bin/rg`、`/usr/local/bin/rg` の順に探す。なければ `ok: false` と理由を返す。ログの場所は `~/.claude/projects`、peer は `~/Library/Application Support/Canopy/settings.json` の `canopy.mirrorPeers`（machine id → `IP:port`）。

検索の順序：

1. 語ごとに `rg -l -L -i --glob '*.jsonl' --glob '!**/subagents/**' -- TERM .` を `~/.claude/projects` で流す。ASCII だけで 4 文字以下の語には `-w` を足す（`-w` は日本語の語の中で一致しなくなるので、ほかの語には付けない）。
2. ファイルの集合を、既定は積、`--any` は和でまとめる。`os.path.realpath` で重複を消す。
3. 各ファイルの最初の `"entrypoint":"…"` を読み、`sdk-` で始まるものを捨てる。
4. 残ったファイルに `rg -L -i --no-line-number --with-filename --null` を全部の語で流す（ファイルは 500 個ずつ）。
5. 2,000,000 バイトより長い行は読まない。ほかの行は JSON として解釈して判定する。行の先頭や末尾だけを見て `type` を推測しない（試作の 84〜100% の漏れの原因の候補）。
6. 本文の条件は設計書のとおり。語ごとの一致数と、一致箇所の前後 80 文字の抜粋を 3 個まで持つ。
7. 一致数の合計の降順、次に `lastActive` の降順に並べ、`--limit` 件について、ファイルからタイトル（`custom-title`、`ai-title` の最後のもの、なければ最初の発言）、最初と最後の発言を読む。

時間切れは、期限を過ぎたら次の処理へ進まず、そこまでの結果で返す。

`--all` は peer ごとにスレッドで走らせる。引数はリモートのシェルを通るので、全部を JSON にして base64 にした 1 語で渡す：`ssh -o BatchMode=yes -o ConnectTimeout=6 <IP> python3 - --b64 <payload>`。標準入力に自分のソースを渡す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test test/find-sessions.test.js`
Expected: PASS

- [ ] **Step 5: 両方の Mac の実データで確かめる**

Run: `python3 Resources/canopy-bridge/skills/find-session/find_sessions.py search --all fdf r6 release`、語を `collision`、`契約`、`tailscale` に変えて同じことをする。mbp と studio の両方から流す。
Expected: どちらも `--timeout` 以内に終わる。全行を解析する確認用のスクリプトを同じ時点で流し、`collision` と `契約` の件数が一致する。設計書の表の値はその後のログで増えているので、比べる相手にしない。ずれたら原因を直す。

- [ ] **Step 6: Commit**

```bash
git add Resources/canopy-bridge/skills/find-session/find_sessions.py test/find-sessions.test.js .github/workflows/ci.yml
git commit -m "Add a stateless session search script"
```

### Task 2: find-session skill を同梱する

**Files:**
- Create: `Resources/canopy-bridge/skills/find-session/SKILL.md`
- Modify: `Sources/Canopy/ShimProcess.swift`（`installBridgeMod()`）
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: Task 1 の CLI
- Produces: `static let bridgeModFiles: [String]`（`ShimProcess`）。Task 3 と Task 10 が足す。

- [ ] **Step 1: 失敗する probe を書く**

`record("bridge mod: every listed file is in the bundle", …)`：`ShimProcess.bridgeModFiles` の全ファイルが `Bundle.main.resourceURL/canopy-bridge` にある。`record("bridge mod: the find-session skill is listed", …)`：`skills/find-session/SKILL.md` と `skills/find-session/find_sessions.py` を含む。一覧の漏れは、`installBridgeMod()` が `nil` を返して Mod 全体が止まるので重要。

- [ ] **Step 2: probe が失敗することを確かめる**

Run: `./scripts/build_debug_stable.sh`、`CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: ビルド失敗（`bridgeModFiles` がない）

- [ ] **Step 3: 実装する**

`installBridgeMod()` の `relativeFiles` を `nonisolated static let bridgeModFiles` に出して、2 ファイルを足す。

`SKILL.md` の `description` は、「どのセッションだったか」「あの件どこ」「where did we discuss」「I lost the session」のような依頼を拾う文にする。本文は設計書の手順 1〜5 と Slack URL の扱いをそのまま書く。呼び出しは次の形：

```
python3 "${CLAUDE_SKILL_DIR}/find_sessions.py" search --all --exclude "${CLAUDE_SESSION_ID}" TERM...
python3 "${CLAUDE_SKILL_DIR}/find_sessions.py" tail SESSION_ID --machine MACHINE_ID
```

- [ ] **Step 4: probe が通ることを確かめる**

Run: Step 2 と同じ
Expected: 新しい 2 件が PASS。`ci.yml` の `EXPECTED_ASSERTIONS` を実数に更新する。

- [ ] **Step 5: 過去の実際の依頼で確かめる**

Run: Debug の Mod フォルダを `CLAUDE_CODE_PLUGIN_DIRS` に入れて `claude -p` で聞く（`CLAUDE_CODE_ENTRYPOINT` は unset）。設計書の「確かめること」の 5 問を、mbp と studio から聞く。
Expected: 4 問は正しいセッションが上位に出て、Mac、プロジェクト、日付、止まった場所が答えに入る。FDF CUP の問いは断定せず、見つからないと答える。別の Mac の IP を一時的に届かない値にすると、答えに「届かない」と出る。

- [ ] **Step 6: Commit**

```bash
git add Resources/canopy-bridge/skills/find-session/SKILL.md Sources/Canopy/ShimProcess.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Ship the find-session skill in the bridge mod"
```

---

## Part B: 開く

### Task 3: canopyctl を同梱する

**Files:**
- Modify: `project.yml`（`scripts/canopyctl` を resource に追加）
- Modify: `Sources/Canopy/ShimProcess.swift`（`installBridgeMod()`、`canopyAssignedEnvKeys`、環境の組み立て）
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces: `<Mod フォルダ>/bin/canopyctl`。skill からは `python3 "${CLAUDE_SKILL_DIR}/../../bin/canopyctl"` で呼ぶ。セッションの環境の `CANOPY_CONTROL_SOCK`。

- [ ] **Step 1: 失敗する probe を書く**

`record("canopyctl: bundled", …)`：`Bundle.main.resourceURL/canopyctl` がある。`record("env: the control socket is canopy-assigned", ShimProcess.canopyAssignedEnvKeys.contains("CANOPY_CONTROL_SOCK"))`

- [ ] **Step 2: 実装する**

`installBridgeMod()` の最後で、バンドルの `canopyctl` を `bin/canopyctl` へコピーする。ローカルのセッションだけ `env["CANOPY_CONTROL_SOCK"] = DaemonPaths.current` を入れる。これで Debug のセッションは Debug の daemon へ届く。`project.yml` を変えたら `xcodegen generate` を流す。

- [ ] **Step 3: probe が通ることを確かめる**

Run: `./scripts/build_debug_stable.sh`、`CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add project.yml Sources/Canopy/ShimProcess.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Ship canopyctl with the bridge mod"
```

### Task 4: show_session

**Files:**
- Create: `Sources/Canopy/ControlBroadcast.swift`
- Modify: `Sources/Canopy/ControlProtocol.swift`、`Sources/Canopy/ControlSession.swift`、`Sources/Canopy/ControlClient.swift`、`Sources/Canopy/CanopyApp.swift`、`Sources/Canopy/SessionStore.swift`、`scripts/canopyctl`、`docs/CONTROL_PROTOCOL.md`
- Modify: `Resources/canopy-bridge/skills/find-session/SKILL.md`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces（Task 9 が使う）：

```swift
@MainActor enum ControlBroadcast {
    static func register(_ session: ControlSession)
    static func unregister(_ session: ControlSession)
    /// Sends to every subscribed local client. Returns how many received it.
    @discardableResult static func toLocalClients(_ frame: [String: Any]) -> Int
}
struct ShowSession: Equatable { let sessionId: String; let machineId: String?; let title: String; let project: String }
ControlProtocol.parseShowSession(_ params: [String: Any]) -> Result<ShowSession, ControlError>
ControlProtocol.showSessionFrame(_ show: ShowSession) -> [String: Any]   // type: "show_session"
SessionStore.showSession(_ show: ShowSession)
```

- [ ] **Step 1: 失敗する probe を書く**

`parseShowSession` について：`sessionId` なしは失敗、大文字の ID は小文字になる、`machineId` は省略でき、空文字は `nil`。`showSessionFrame` を `ControlClient` の解釈へ通すと元の値に戻る。

- [ ] **Step 2: probe が失敗することを確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: ビルド失敗

- [ ] **Step 3: 実装する**

- `ControlSession`：`subscribe` で `isLocal` のとき `ControlBroadcast.register(self)`、`stop()` で `unregister`。`ControlBroadcast` は弱参照で持つ。`send` を内部公開する。
- verb `show_session`：`isLocal` のガードのあと parse し、`toLocalClients` が 0 なら `fail(request, "Canopy is not open on this Mac", code: "no_gui")`、1 以上なら `reply(request, ["shown": true])`。
- `ControlClient`：`case "show_session":` で `onShowSession?(show)`。`CanopyApp.startDaemonControl` でつなぐ。
- `SessionStore.showSession`：`machineId` があれば `openRemoteRecent(machineId:, machineName: remoteRosters[id]?.displayName ?? id, recent: MirrorRecents.Session(id:, title:, project:, timestamp: Date()), target: .newPane)`。なければ、開いているセッションは `focusOrPane(_, target: .newPane)`、閉じていれば `resolveClosedSession(sessionId:, localCwd: nil)` の結果で `openNew(directory:, resumeId:, sessionTitle:, permissionMode: CanopySettings.shared.defaultPermissionMode, customApi: ModelProviderStore.selectedProvider(), target: .newPane)`。失敗は `noteSessionFailure`。
- `canopyctl`：`show SESSION_ID [--machine ID] [--title T] [--project P]`。
- `SKILL.md`：「開いて」と言われたときの呼び出しを足す。
- `docs/CONTROL_PROTOCOL.md`：verb と通知を書く。

- [ ] **Step 4: probe が通ることを確かめる**

Run: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS。`EXPECTED_ASSERTIONS` を更新する。

- [ ] **Step 5: 実機で確かめる**

Debug ビルドで、手元の閉じたセッション、開いているセッション、別の Mac の閉じたセッション、別の Mac で動いているセッションを `canopyctl show` で開く。
Expected: 順に、新しいペイン、既存のペインが前に出る、mirror ペイン、mirror ペインで参加。

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy scripts/canopyctl docs/CONTROL_PROTOCOL.md Resources/canopy-bridge/skills/find-session/SKILL.md .github/workflows/ci.yml
git commit -m "Open a found session in a pane from the find-session skill"
```

---

## Part C: No folder

### Task 5: No folder の実体と表示

**Files:**
- Create: `Sources/Canopy/NoFolder.swift`
- Modify: `Sources/Canopy/GitWorktree.swift`（`projectDisplayName`）、`Sources/Canopy/RecentDirectories.swift`（`load`、`add`）
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces：

```swift
enum NoFolder {
    static let displayName = "No folder"
    static var directory: URL            // ~/Library/Application Support/Canopy/no-folder
    static func isNoFolder(_ url: URL) -> Bool   // compares resolved paths
    @discardableResult static func prepare() -> URL   // creates it and writes CLAUDE.md when it differs
    static let instructions: String      // the CLAUDE.md body
}
```

- [ ] **Step 1: 失敗する probe を書く**

- `isNoFolder` は末尾のスラッシュとシンボリックリンク違いでも真、ほかのフォルダは偽。
- `GitWorktree.projectDisplayName(for: NoFolder.directory)` は `No folder`。
- `RecentDirectories.add(NoFolder.directory)` のあとも `load()` に入らない。これが漏れると、次の ⌘N が No folder を選んでしまう。probe は `recentDirectories` を書くので、元の値を `defer` で戻す。
- `prepare()` は `CLAUDE.md` を作り、2 回目は更新時刻を変えない。

- [ ] **Step 2: probe が失敗することを確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: ビルド失敗

- [ ] **Step 3: 実装する**

`instructions` は設計書の 3 点を書く。`projectDisplayName` の先頭で `NoFolder` を判定する。`RecentDirectories` は `isManagedWorktree` と同じ位置で除外する。

- [ ] **Step 4: probe が通ることを確かめる**

Run: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Canopy/NoFolder.swift Sources/Canopy/GitWorktree.swift Sources/Canopy/RecentDirectories.swift Sources/Canopy/_SidebarLogicProbe.swift .github/workflows/ci.yml
git commit -m "Add the No folder directory"
```

### Task 6: Launcher と ⌘⇧N

**Files:**
- Modify: `Sources/Canopy/LauncherView.swift`（`directoryChip`、`directoryLabel`、`preselectMostRecentDirectory`）
- Modify: `Sources/Canopy/SessionStore.swift`、`Sources/Canopy/CanopyApp.swift`
- Modify: `docs/notes/session-management.md`（ショートカット）
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `NoFolder`
- Produces: `SessionStore.openLauncherWithoutFolder()`、`SessionStore.launcherWantsNoFolder: Bool`（Launcher が読んだら `false` に戻す）

- [ ] **Step 1: 失敗する probe を書く**

`openLauncherWithoutFolder()` のあと `launcherWantsNoFolder` が真、Launcher がペインに出ている。ペインが 0 枚のときは `selection == .launcher`。

- [ ] **Step 2: 実装する**

- `openLauncherWithoutFolder()` は `NoFolder.prepare()` のあと、⌘N と同じ分岐で Launcher を開き、フラグを立てる。
- `LauncherView` はフラグを `.onAppear` と `.onChange` の両方で読み、`selectedDirectory = NoFolder.directory` にする。Launcher がすでに出ているときも効かせるため。
- `directoryChip` のメニューの先頭に `Button(NoFolder.displayName)` を足す。`directoryLabel` は No folder のとき `NoFolder.displayName` を返す。
- `CanopyApp` の `New Session` の下に `Button("New Session Without Folder")` と `.keyboardShortcut("n", modifiers: [.command, .shift])` を足す。

- [ ] **Step 3: probe が通ることを確かめる**

Run: `./scripts/build_debug_stable.sh`、`CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS

- [ ] **Step 4: 実機で確かめる**

⌘⇧N、質問を打って開始、応答、閉じて開き直す。そのあと ⌘N。
Expected: セッションが `no-folder` で動き、サイドバーの表示は `No folder`。閉じたあとも同じ。⌘N は今までどおり直近のフォルダを選ぶ。

- [ ] **Step 5: Commit**

```bash
git add Sources/Canopy docs/notes/session-management.md .github/workflows/ci.yml
git commit -m "Start a session without choosing a folder"
```

---

## Part D: 移動

### Task 7: shim から CLI へ set_cwd を送る

**Files:**
- Create: `Resources/vscode-shim/cli-control.js`
- Create: `test/cli-control.test.js`
- Modify: `Resources/vscode-shim/index.js`、`.github/workflows/ci.yml`

**Interfaces:**
- Produces：

```js
// cli-control.js
trackCliSpawn(child_process)            // keeps the child whose args include --input-format
sendSetCwd({ requestId, path, trustedDirectory }, write)
// write receives { type: "set_cwd_result", requestId, response } or { ..., error }
```

Swift から shim へは `{"type":"set_cwd","requestId":…,"path":…,"trustedDirectory":…}`。

- [ ] **Step 1: 失敗するテストを書く**

偽の child（`EventEmitter` の `stdout`、配列に記録する `stdin.write`、`exitCode`）で確かめる。

| テスト名 | 確かめること |
|---|---|
| `writes one control_request line` | `subtype: "set_cwd"`、`path` がある。`trustedDirectory` がなければ `trust_accepted` を送らない |
| `sends the trust fields only with trustedDirectory` | `trust_accepted: true` と `trusted_directory` |
| `returns the matching control_response` | ほかの行と別の `request_id` は無視する |
| `handles a response split across chunks` | 行が 2 回に分かれて届く |
| `stops listening after the response` | `stdout` のリスナーが残らない |
| `reports an error without a running CLI` | child がない、`exitCode` が null でない |

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `node --test test/cli-control.test.js`
Expected: FAIL

- [ ] **Step 3: 実装する**

`trackCliSpawn` は `index.js` の既存の spawn の包みより後で呼ぶ。stdout のリスナーは送信の直前に足して、応答で外す。起動時から付けると、拡張機能が読み始める前にストリームが流れ出す。`index.js` の `startStdinReader` に `set_cwd` の分岐を足す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)`
Expected: PASS。`CI_TEST_FILES` と `EXPECTED_TESTS` を更新する。

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/cli-control.js Resources/vscode-shim/index.js test/cli-control.test.js .github/workflows/ci.yml
git commit -m "Send set_cwd to the CLI from the shim"
```

### Task 8: 移動の本体

**Files:**
- Create: `Sources/Canopy/SessionMove.swift`
- Modify: `Sources/Canopy/ShimProcess.swift`、`Sources/Canopy/SessionStore.swift`、`Sources/Canopy/OpenSession.swift`、`Sources/Canopy/ControlProtocol.swift`、`Sources/Canopy/ControlSession.swift`、`scripts/canopyctl`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces（Task 9 が使う）：

```swift
enum SessionMove {
    static let busyRetryInterval: TimeInterval = 3
    static let busyRetryLimit = 10
    enum CLIReply: Equatable {
        case ok(cwd: String, changed: Bool)
        case needsTrust(directory: String, trustRoot: String?)
        case busy
        case rejected(reason: String, message: String)
        case malformed
    }
    static func parseReply(_ wire: [String: Any]) -> CLIReply
    enum Next: Equatable { case restart(URL), stay, retry, askTrust(directory: String, trustRoot: String?), fail(String) }
    static func next(after reply: CLIReply, retries: Int) -> Next
    /// Why this session cannot move, or nil.
    static func refusal(isRemote: Bool, isInWorktree: Bool, path: String,
                        isDirectory: (String) -> Bool) -> String?
}
// ShimProcess
func requestMove(to path: String)
static let sessionMovedNotification: Notification.Name
static let movedToKey: String
// SessionStore
func finishMove(shim: ShimProcess, to directory: URL)
// ControlProtocol.SessionRow と OpenSession
var moveCount: Int   // wire: "moveCount", absent = 0
```

`canopyctl move --session-id ID --path PATH` もここで足す。

`followsCheckoutMove` は変えない。probe の `checkout move: nowhere to go → stay` がこの関数の性質を守っている。

- [ ] **Step 1: 失敗する probe を書く**

- `parseReply`：`ok`、`needs_trust`、`rejected` の `busy` とそれ以外、`status` のない形。実物の `control_response.response.response` の形で書く。
- `next`：`ok(changed: true)` は `.restart`。**`ok(changed: false)` は `.stay`**。`busy` は `retries < busyRetryLimit` で `.retry`、上限で `.fail`。`needsTrust` は `.askTrust`。`rejected` は `.fail` でメッセージを含む。
- `refusal`：SSH remote、worktree、相対パス、存在しないパスは文字列を返す。普通のフォルダは `nil`。
- `SessionRow` の `moveCount`：wire を往復する。キーがなければ 0。

- [ ] **Step 2: probe が失敗することを確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: ビルド失敗

- [ ] **Step 3: 実装する**

- verb `move_session`：`isLocal` のガード、`requestedSession`、`session.shim` の確認、`SessionMove.refusal`。問題なければ `shim.requestMove(to:)` を呼び、`reply(request, ["status": "queued"])`。worktree の判定は、`ShimProcess.effectiveVCSDirectory` で得た実効フォルダに `GitWorktree.isManagedWorktree` と `GitWorktree.checkoutOfWorktreeRoot` を当てて行う。途中で worktree に入ったセッションもこれで断れる。
- `ShimProcess.requestMove`：`pendingMove` にラッチして、`moveToCheckoutWhenQuiet` と同じ形で 1 秒後に `restartLosesWork` を見る。忙しければラッチを残して、次のターン終了（`checkForRemovedFolder()` を呼んでいる箇所）で再度試す。`resetActivityState()` で消す。
- 静かになったら Task 7 の `set_cwd` を送る。`handleShimMessage` の `set_cwd_result` で `parseReply` と `next` を通す。`.retry` は `busyRetryInterval` 後に再送。`.restart` は `sessionMovedNotification` を投げる。
- `SessionStore.finishMove`：`moveToCheckout` と同じ手順。`session.origin = .local(directory)`、`session.project`、`session.moveCount += 1`、`restartSession(session.id, notifyDaemon: false, mirrorsReattach: headless)`、headless なら `startHeadlessSession`。通知の購読は `worktreeRemovedNotification` の隣に足す。
- `applyDaemonSessions`：`row.moveCount != session.moveCount` なら値を写し、`row.cwd` が今の `origin` と違うときだけ `origin` と `project` を差し替える。ペインの再接続は、既存の checkout 追従と同じ条件で行う。
- `.askTrust` と `.fail` は、この Task では `logger.error` に出して終える。Task 9 でつなぐ。

- [ ] **Step 4: probe が通ることを確かめる**

Run: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS。`EXPECTED_ASSERTIONS` を更新する。

- [ ] **Step 5: 実機で確かめる**

信頼済みのフォルダへ `canopyctl move` で移動する。そのあとターン、リロード、閉じて開き直す。ターン実行中にも頼む。実際の Git リポジトリへも移動する。
Expected: 試作と同じ結果。表示、履歴、記憶、`CLAUDE.md`、`pwd`、リロードが正常。ターン中の依頼は、終わってから動く。Git リポジトリではブランチ表示と `@` のファイル検索が新しいフォルダを指す。

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy scripts/canopyctl .github/workflows/ci.yml
git commit -m "Move a session to another folder"
```

### Task 9: 信頼の確認と失敗の通知

**Files:**
- Modify: `Sources/Canopy/SessionMove.swift`、`Sources/Canopy/ShimProcess.swift`、`Sources/Canopy/ControlSession.swift`、`Sources/Canopy/ControlClient.swift`、`Sources/Canopy/CanopyApp.swift`、`Sources/Canopy/SessionStore.swift`、`docs/CONTROL_PROTOCOL.md`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `ControlBroadcast.toLocalClients`、`SessionMove.Next.askTrust`
- Produces：

```swift
SessionMove.trustTimeout: TimeInterval = 60
SessionMove.noGuiMessage: String
SessionMove.deniedMessage: String
enum SessionMove.AskOutcome: Equatable { case wait, refuse(String) }
SessionMove.askOutcome(localClients: Int) -> AskOutcome
struct SessionMove.TrustRequest: Equatable {
    let moveId: String
    let directory: String
    /// The decision, or nil when the answer is for another move.
    func resolve(moveId: String, accepted: Bool) -> Bool?
}
struct MoveTrustAnswer: Equatable { let moveId: String; let accepted: Bool }
ControlProtocol.parseAnswerMoveTrust(_ params: [String: Any]) -> Result<MoveTrustAnswer, ControlError>
// daemon → GUI
{"type":"confirm_move_trust","moveId":…,"sessionTitle":…,"directory":…,"trustRoot":…}
{"type":"session_notice","title":…,"message":…}
// GUI → daemon
verb answer_move_trust { moveId, accepted }
```

`trust_accepted` の根拠は `answer_move_trust` の `accepted: true` だけ。`move_session` に信頼の引数はない。`moveId` は `ShimProcess` が UUID で作り、`move_session` の返事には含めない。

- [ ] **Step 1: 失敗する probe を書く**

- `askOutcome(localClients: 0)` は `.refuse(noGuiMessage)`。`askOutcome(localClients: 1)` は `.wait`。
- `parseAnswerMoveTrust`：`moveId` なしは失敗。`accepted` が真偽値でなければ `accepted: false`。
- `TrustRequest.resolve`：別の `moveId` は `nil`。同じ `moveId` は `accepted` の値。

- [ ] **Step 2: probe が失敗することを確かめる**

Run: `./scripts/build_debug_stable.sh`
Expected: ビルド失敗

- [ ] **Step 3: 実装する**

- `.askTrust`：`ControlBroadcast.toLocalClients` で確認を送り、受け取った数を `askOutcome` に通す。`.refuse` なら失敗の通知へ。`.wait` なら `TrustRequest` をラッチして `trustTimeout` のタイマーで待つ。時間切れは `resolve(accepted: false)` と同じ経路を通す。ラッチは `resetActivityState()` で消す。
- `answer_move_trust`：`isLocal` のガードのあと、セッションを持つ `ShimProcess` へ渡す。承認なら `trustedDirectory` 付きで `set_cwd` を再送する。
- GUI の `confirm_move_trust`：`NSAlert` を出す。文面は `Move this session to <folder>?`、説明は `Claude Code will trust this folder and may run its hooks and MCP servers.`、ボタンは `Move` と `Cancel`。`trustRoot` があれば信頼の範囲としてそのパスを出す。
- 失敗の通知：`session_notice` を `ControlBroadcast` で送り、GUI は `noteSessionFailure(title:, message:, status: -2)` で出す。
- `docs/CONTROL_PROTOCOL.md` に verb と通知を足す。

- [ ] **Step 4: probe が通ることを確かめる**

Run: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
Expected: PASS

- [ ] **Step 5: 実機で確かめる**

未信頼のフォルダへ移動する。`Cancel`、`Move`、放置の 3 回。
Expected: `Cancel` と放置は移動せず、理由が出る。`Move` は移動して、`~/.claude.json` に信頼が記録される。2 回目は確認が出ない。

- [ ] **Step 6: Commit**

```bash
git add Sources/Canopy docs/CONTROL_PROTOCOL.md .github/workflows/ci.yml
git commit -m "Ask before moving a session to an untrusted folder"
```

### Task 10: move-session skill と仕上げ

**Files:**
- Create: `Resources/canopy-bridge/skills/move-session/SKILL.md`
- Modify: `Sources/Canopy/ShimProcess.swift`（`bridgeModFiles`）、`Sources/Canopy/NoFolder.swift`（`instructions`）
- Create: `docs/notes/learnings-session-move.md`
- Modify: `CLAUDE.md`（note の一覧）、`docs/notes/source-files.md`

**Interfaces:**
- Consumes: `canopyctl move`、`bridgeModFiles`
- Produces: skill `move-session`

- [ ] **Step 1: 実装する**

`SKILL.md` の手順：

1. 移動先のフォルダを決める。本人が名前で言ったら、`~/repos` の下などから絶対パスを確かめる。候補が複数なら聞く。
2. フォルダを新しく作るのは、本人が頼んだときだけ。
3. `python3 "${CLAUDE_SKILL_DIR}/../../bin/canopyctl" move --session-id "${CLAUDE_SESSION_ID}" --path <絶対パス>` を呼ぶ。
4. 「このターンが終わると移動する。初めてのフォルダなら確認画面が出る」と伝えて、ターンを終える。

`learnings-session-move.md` には、`set_cwd` の契約、`/cd` が使えないこと、再起動が必須な理由、信頼済みが少ない事実を書く。計測値は code の doc comment に書き、note からはリンクする（`CLAUDE.md` の「Where new knowledge goes」）。

- [ ] **Step 2: probe と全テストを流す**

Run: `./scripts/build_debug_stable.sh`、`CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`、`node --test $(sed -n 's/.*CI_TEST_FILES: "\(.*\)"/\1/p' .github/workflows/ci.yml)`
Expected: 全部 PASS

- [ ] **Step 3: 通しで確かめる**

⌘⇧N、`Create new folder spike-test under /tmp and move there`、応答、続きのターン。次に ⌘⇧N で、過去の話を聞いて「開いて」。
Expected: 成功の条件 1〜4 がすべて満たされる。

- [ ] **Step 4: Commit**

```bash
git add Resources/canopy-bridge/skills/move-session/SKILL.md Sources/Canopy docs/notes CLAUDE.md .github/workflows/ci.yml
git commit -m "Add the move-session skill"
```
