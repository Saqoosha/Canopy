# Canopy Server Plan B5 — 他の Mac と phone を daemon に繋ぐ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 他の Mac と phone が Tailscale 越しに繋ぐ先を、GUI の mirror listener から daemon に移す。B2 以降、local の session は daemon にあるので、GUI の listener に繋いでも session が見つからない。これで目標 (a) の「他の Mac の session を開く・新しく始める」が daemon 上で動く。

**Architecture:** daemon の Tailscale listener を `canopy.mirrorPort`（既定 8770、Debug は +1）で開く。今まで GUI が開いていたポートなので、Mac と phone のペアリング（connection string の host:port）は張り直さずに使える。GUI は、local の session を daemon が持っている間は自分の listener を開かない。Settings › Sharing の Status と Copy Connection は、daemon に `mirror_status` を聞いて出す。使われなくなる `canopy.daemonPort` は消す。

**Spec:** [docs/superpowers/specs/2026-09-29-canopy-server-design.md](../specs/2026-09-29-canopy-server-design.md)。B4 は PR #271。B5 はその上の stacked PR（base: `canopy-server-b4`）。

## Global Constraints

- ブランチ `canopy-server-b5`、PR の base は `canopy-server-b4`、draft
- ポート番号は変えない（Release は 8770 のまま）。変えると phone と他の Mac のペアリングが全部切れる
- probe の assertion を足したら `EXPECTED_ASSERTIONS` を上げる

## Review Focus

1. **listener が 2 つにならない。** GUI は `localSessionsRunInDaemon` の間は `MirrorServer` の TCP を開かない。同じポートを取り合うと片方が EADDRINUSE で落ちる
2. **Settings の表示が daemon の実際の状態。** daemon が落ちているときは「daemon に繋がらない」と出す。GUI の推測で Listening と出さない
3. **パスワードのリセット。** GUI が keychain の token を替えたら、daemon は次の tick で既存の接続を切る（`refreshToken`、Plan A で入っている）

---

### Task 1: daemon のポートを `mirrorPort` にする

**Files:** `DaemonConfig.swift`、`CanopySettings.swift`、`CanopyDaemon.swift`、`_SidebarLogicProbe.swift`、`ci.yml`

- [ ] `DaemonConfig.daemonPort` → `port`。`canopy.mirrorPort` から読む。既定 8770
- [ ] `CanopySettings.daemonPort` を消す
- [ ] daemon の `applyTCP`：パスワードが無いとき・Tailscale が無いときも `MirrorServerStatus.shared.state` を入れる（`.noPassword` / `.noTailscale`）。止めたら `.off`
- [ ] probe：`DaemonConfig.parse` が `canopy.mirrorPort` を読む（既存の assertion を置き換え）

### Task 2: `mirror_status`

**Files:** `MirrorServer.swift`（`MirrorServerStatus.State` の wire）、`ControlSession.swift`、`CanopyApp.swift`、`SettingsView.swift`

- [ ] `MirrorServerStatus.State.wire` と `init?(wire:)`
- [ ] verb `mirror_status` → `{"status": state.wire}`
- [ ] GUI：`localSessionsRunInDaemon` の間は `syncMirrorServer` で listener を開かない。Settings が見えている間、2 秒ごとに `mirror_status` を聞いて `MirrorServerStatus.shared.state` に入れる。control に繋がっていなければ `.failed("Canopy's background service is not running")`
- [ ] probe：State の 5 通りの round trip、未知の値は nil

### Task 3: 確認

- [ ] ビルド、probe
- [ ] Debug の daemon が `mirrorPort + 1` で listen する（ログ）
- [ ] Debug の GUI と daemon で Settings の Status が daemon の状態を出す（GUI を起動できるときだけ。roster が On の Mac では keychain のダイアログが出るので、Saqoosha に頼む）
- [ ] 他の Mac からの attach（studio）：Release の署名で両方の Mac に入れてから Saqoosha と確かめる

## 見送り

- 他の Mac の daemon に control 接続を張って、その Mac の sidebar をそのまま並べる（spec の「client の組み立て」）。今は roster（relay）と `list_recents` でマシンごとの一覧を出している。それで開く・新規・resume はできる
- remote の daemon の設定をこの Mac から変える（spec の未決）
