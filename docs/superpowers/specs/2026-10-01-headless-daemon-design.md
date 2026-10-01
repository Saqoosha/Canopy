# daemon を LaunchServices の app にしない

2026-09-29 の [Canopy Server 設計](2026-09-29-canopy-server-design.md) では、daemon を「同じ binary の別モード」として、`NSApplication` の accessory app で起動した。その結果、LaunchServices（LS）は daemon を「`sh.saqoo.Canopy` の 2 つ目のインスタンス」として登録する。3.0.x で起きている症状のうち 4 つは、この登録が原因。この spec では、daemon が `NSApplication` を作らないようにして、LS に登録されないようにする。bundle 構成、署名、TCC の identity は変えない。

## 症状（2026-10-01 実測）

1. **GUI を閉じたあと、Dock からも Finder からも開き直せない。** macOS 27 の Dock は、daemon を「Canopy — Running in Background」としてタイルに残す。アイコンをクリックすると、LS は新しい GUI を起動せずに既存のインスタンス（daemon）を前に出そうとする。だから何も開かない。開き直すには、Dock の context menu で Quit して daemon を殺すしかない。そうすると全セッションが止まる。
2. **Sparkle の更新が daemon を quit する。** Updater は、インストールの前に同じ bundle の全インスタンスへ quit Apple Event を送る（この Mac の 12:16:23、studio の 12:17:51 で観測）。daemon は `DaemonUpgrade` の告知経路を通らずに止まる。daemon が launchd 管理下にいても、quit は exit 0 になる。`KeepAlive.SuccessfulExit=false` なので、launchd は再起動しない。
3. **Sparkle 更新のあと GUI が再起動しないことがある。** Updater の relaunch を、LS が終了処理中の daemon に解決する（studio の 12:17:51.985 に `LAUNCHING … changing application type to Foreground from UIElement` / `SETFRONT: pid=88024`）。新しい GUI は起動せず、その daemon が 0.3 秒後に終了して、何も残らない。daemon の終了が relaunch より先に終われば成功する。つまり競合。
4. **初回登録のあと、launchd の daemon が負ける。** GUI が `register()` すると、launchd が `RunAtLoad` で daemon を起動する。同時に `DaemonSupervisor` は、socket がまだ無いのを見て、自分でも daemon を起動する（`registration == .enabled` のときは `.launch`）。この Mac と studio の両方で、Supervisor が起動した方が socket を取った。launchd の方は「another daemon serves the local socket」で exit 0 し、二度と起こされない。以後の daemon はずっと launchd 管理外。4 は LS とは別の原因なので、別に直す。

## spike の結果

scratchpad の probe app（`LSProbe.app`。ad-hoc 署名の通常 app で、`LSUIElement` は付けていない）で測った。

| daemon の作り | LS 登録（`lsappinfo`） | daemon 稼働中に `open` |
|---|---|---|
| `NSApplication` + `.accessory`（今と同じ） | `type="UIElement"` で登録 | GUI が起動しない（症状 1 を再現） |
| `NSApplication` なし、`RunLoop.main.run()`、launchd 起動 | 登録なし | 新しい GUI が起動 |
| 同上、posix_spawn で起動 | 登録なし | 新しい GUI が起動 |
| 同上 + `NSWorkspace.shared.open`、`UNUserNotificationCenter`、WebKit と SwiftUI の `dlopen` | 登録なし | 新しい GUI が起動 |

bundle id 宛ての quit（`tell application id … to quit`。Sparkle や Dock と同じ届き方）は GUI だけを終わらせ、`NSApplication` なしの daemon は残った。

## 決めたこと

- **daemon は `NSApplication` を作らない。** `CanopyDaemon.run()` は `DaemonDelegate` の起動処理を直接呼んでから、`RunLoop.main.run()` で回す。`dispatchMain()` は使わない。daemon の timer は全部 `Timer.scheduledTimer`（default mode）で、`dispatchMain()` の下では発火しないから。`DaemonDelegate` は `NSApplicationDelegate` をやめる。`NSApp.run` がイベントごとに張っていた autorelease pool の代わりに、run loop の 1 回ごとに `autoreleasepool {}` を張る。
- **SIGTERM は `shutDown(); exit(0)`。** 今は `NSApp.terminate` から `applicationWillTerminate` を経て `shutDown()` に行く。それ以外に `applicationWillTerminate` に依存しているものは無い。upgrade の経路と `onLocalFailure` は、すでに `shutDown()` → `exit()` を直接呼んでいる。
- **`ShimProcess.postTaskCompletedNotification` は daemon で `NSApp` に触らない。** `NSApp` は暗黙アンラップの optional なので、`NSApplication` が無いと `NSApp.isActive` で crash する。到達するのは、ターンが終わってどの UI client も attach していないとき。daemon では「前面にいる UI は無い」とみなして、今と同じくバナーを出す。今の accessory の daemon でも `isActive` は常に false なので、挙動は変わらない。`NSApplication` なしのプロセスからでも `UNUserNotificationCenter.add` のバナーは表示される（2026-10-01 に Debug で実測。usernoted が `Presenting`）。phone への push（`RosterNotifier`）は AppKit に依存しないので影響しない。
- **Supervisor の直接起動は `Process` にする。** `NSWorkspace.openApplication` は LS の app として起動するので使わない。`Contents/MacOS/Canopy --daemon` を `Process` で起動して、終了は待たない。GUI が終わっても子プロセスは残り、launchd（pid 1）に引き取られる。
- **登録済みなら、まず launchd に起こさせる（症状 4）。** `registration == .enabled` で socket が無いとき、Supervisor は `launchctl kickstart gui/<uid>/<label>` を実行して、socket を最大 15 秒待つ。exit 0 で止まった job も kickstart で起こし直せる（2026-10-01 に Debug で実測、56 ms）。それでも上がらないときだけ、`Process` で直接起動する。`register()` した直後（`.register` の分岐）も、直接起動せずに socket を待つ。Debug（未登録）は今と同じく直接起動。これで、#275 の「再起動の告知より前に始まった起動が launchd を待たない」も閉じる。登録済みの build が直接起動するのは、告知の有無によらず、launchd が起こせなかったときだけになるので。
- **LaunchAgent の plist、bundle、署名、TCC は変えない。** daemon の identity は今と同じ `Canopy.app`。FDA はそのまま効く。

## 移行

3.0.x の daemon は `NSApplication` で動いている。この版への更新では、Sparkle が古い daemon を quit する（今と同じ）。症状 3 の競合も、この更新では起こりうる。更新後の GUI が起動したら、Supervisor が launchd の job を kickstart して、新しい daemon が `NSApplication` なしで起動する。そこから先の更新では、Sparkle は daemon に触れない。daemon は `DaemonUpgrade` の告知経路（新しい build を検出 → 告知 → exit 1 → launchd が再起動）で入れ替わる。この版へ上げる 1 回だけは、セッションが告知なしで止まる。

## 検証

- probe（`_SidebarLogicProbe`）: `DaemonSupervisor.action` に `.enabled` で socket なしの分岐を足し、kickstart 経由になることを固定する。
- 実機、この Mac と studio の両方で確かめる。
  - daemon 稼働中に `lsappinfo list` を見て、`sh.saqoo.Canopy` が GUI の 1 件だけであること。
  - GUI を Cmd+Q で終える。Dock のタイルが消え、アイコンのクリックで GUI が開き直すこと。
  - `launchctl print gui/$(id -u)/sh.saqoo.Canopy.daemon` で `state = running`、pid が daemon のものであること。
  - 次の Sparkle 更新で、GUI が再起動し、daemon が「restarting for build」を log して launchd に入れ替えられること。
  - ターン完了時、UI client が無ければ通知バナーが出ること（出なければ、決めたとおり daemon のバナーをやめる）。

## やらないこと

- helper bundle への分離。症状 1〜3 は LS の登録を外すだけで消え、4 は Supervisor の修正で消える。分離すると FDA の取り直し、二重の署名、+11 MB が付いてくる。
- daemon の Dock 表示や Login Items の UI を作り込むこと。
