# Canopy Server Plan B4 — roster と phone からの返信を daemon に移す

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B2 で local の session が daemon に移り、phone から見えなくなった。返信も届かなくなった。roster の publish、phone からの返信と permission の判断の振り分け、利用量を daemon に戻す。

**Architecture:** `RosterPublisher` を daemon で動かす。返信と判断の振り分け（今は `AppDelegate.startRosterPublisher` の closure）は `RosterRouting` に切り出し、GUI と daemon が同じものを使う。GUI は、local の session を daemon が持っている間は publish しない。同じ `machineId` で 2 つ publish すると roster を取り合うため。daemon は `settings.json` を書き戻さない読み取り専用モードで `CanopySettings` を持ち、ファイルが変わったら読み直す。これで roster の On/Off、endpoint、表示名、keep-alive、recap の切り替えが daemon にも届く。

**Tech Stack:** Swift 6 / macOS 15、URLSessionWebSocketTask。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)。B3 は PR #270。B4 はその上の stacked PR（base: `canopy-server-b3`）。

## Global Constraints

- ブランチ `canopy-server-b4`、PR の base は `canopy-server-b3`、draft
- **Debug の daemon は relay にも keychain にも触れない。** `CANOPY_DAEMON_ROSTER=1` のときだけ触れる。Debug の署名は Release の keychain ACL に合わないので読むたびに確認ダイアログが出る。さらに `machineId` が `IOPlatformUUID` なので、Release の Canopy と同じ roster を取り合う（CLAUDE.md の probe と roster の learning と同じ理由）
- daemon は `settings.json` を書かない（`CanopySettings.persistsChanges = false`）
- GUI の in-process の session（SSH remote）の挙動は、roster に出ないこと以外は変えない。SSH remote は Plan D で消える
- probe の assertion を足したら `EXPECTED_ASSERTIONS` を上げる

## Review Focus

1. **publisher が 2 つにならない。** GUI は `localSessionsRunInDaemon` の間は `RosterPublisher` を作らない。Debug の daemon は opt-in なしで作らない
2. **daemon が settings.json を書かない。** 読み直しは `isLoading` と同じ仕組みで save を止める。書き込みは 1 回も起きない（Task 1 に test）
3. **返信の振り分けが GUI と daemon で同じ。** closure の複製ではなく `RosterRouting` を共有する

---

### Task 1: 読み取り専用の `CanopySettings` と読み直し

**Files:** `Sources/Canopy/CanopySettings.swift`、`_SidebarLogicProbe.swift`、`ci.yml`

- [ ] `nonisolated(unsafe) static var persistsChanges = true`。false のとき `save()` は何もしない。`shared` を最初に触る前に daemon が false にする
- [ ] `init(filePath:)` を internal にする（probe が一時ファイルで使う）
- [ ] `reload()`：ファイルを読み直して値を入れる。`load()` と違い、最後の `save()` をしない
- [ ] probe：一時ファイルの値が読める、読み直すと変わった値が入る、`persistsChanges = false` のとき値を変えてもファイルの中身が変わらない

### Task 2: `RosterRouting`

**Files:** Create `Sources/Canopy/Roster/RosterRouting.swift`。Modify `CanopyApp.swift`

- [ ] `AppDelegate.startRosterPublisher` の `onReply` / `onDecision` の closure を `RosterRouting.install(on:store:)` に移す。中身とログは変えない

### Task 3: daemon で publish する

**Files:** `CanopyDaemon.swift`、`CanopyMain.swift`、`CanopyApp.swift`、`Roster/RosterPublisher.swift`、`Roster/RosterNotifier.swift`、`Roster/RosterImageUploader.swift`

- [ ] `RosterPublisher.relayAllowed(isDaemon:isDebug:env:)`（純粋関数）：GUI は今までどおり true。daemon は Release なら true、Debug は `CANOPY_DAEMON_ROSTER=1` のときだけ true
- [ ] プロセスの判定を `static var relayAllowedInProcess` に持たせ、`sharedSecret()` / `sharedSecretForNotifier()` の手前で見る。false なら keychain を読まずに nil
- [ ] daemon：`CanopySettings.persistsChanges = false`、publisher を作って `RosterRouting.install`、`start()`。config の tick で `settings.json` の mtime が変わったら `CanopySettings.shared.reload()`
- [ ] daemon の起動時に `ClaudeUsageDirect.refreshLocalAccount()`：shim が 1 つも無くても roster に利用量が載る
- [ ] GUI：`OpenSession.localSessionsRunInDaemon` の間は `startRosterPublisher` が publisher を作らない
- [ ] probe：`relayAllowed` の 4 通り

### Task 4: 確認

- [ ] ビルド、probe
- [ ] Debug の daemon を起動し、opt-in なしで roster が始まらないこと（`Roster` のログが無い、keychain のダイアログが出ない）をログで確かめる
- [ ] Debug の daemon が settings.json を書かないこと（起動前後で mtime が変わらない）
- [ ] relay への publish と phone からの返信の実機確認は、Release の署名が要るので Saqoosha に頼む

## 見送り

- phone の行順：daemon には pane が無いので `openSessions` の順になる。GUI の pane 順を daemon に伝える経路は無い
- unread：`unreadSessionIds` は GUI の MacroPad が持つので、daemon の roster に unread の状態は出ない
- phone の live mirror（Tailscale の TCP attach）は GUI の `mirrorPort` に繋ぐ。local の session はもうそこに無い → B5 で daemon のポートに移す
- SSH remote の session は phone から見えなくなる（Plan D で消える経路）
