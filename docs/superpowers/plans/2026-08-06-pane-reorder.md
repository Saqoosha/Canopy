# ペイン並べ替え Implementation Plan

> **このプランは実行済みで、内容は出荷版より古い。** PR #126 のレビューで設計が変わり、`movePanesFollowingDrag(draggedIds:)` は `syncPaneOrderToRows()`（行順への単純ソート）に置き換わり、`moveRowFollowingPaneAssignment` とサイドバーのアニメーション、ハイライトのチップ化が追加された。**現状を知りたいならこのファイルではなく spec と実コードを読むこと。** 以下は当時の計画としての記録。

**Goal:** サイドバーの open 行をドラッグすると、そのセッションのペインが対応する左右位置へ移動する。

**Architecture:** `SessionStore.moveOpenSessions` の末尾で、ドラッグされたセッションの `PaneSlot` だけを新しい順位へ移す。全体の再ソートはしない。あわせて、open 行の Cmd+click を素のクリックとして扱い、既に開いているセッションからペインが右端に生える経路を閉じる。

**Tech Stack:** Swift 6 / SwiftUI / macOS 15+（Xcode 26 ツールチェーン必須）

**Spec:** `docs/superpowers/specs/2026-08-06-pane-reorder-design.md`

## Global Constraints

- 作業ワークスペースは `/Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap`（jj workspace `pane-swap`、`main` @ d019df1f から分岐）。default ワークスペース `/Users/hiko/repos/Personal/Canopy` には触らない
- バージョン管理は `jj`。`git` コマンドは使わない
- **コミット（`jj describe`）はユーザーの明示的な指示があるまで実行しない**（CLAUDE.md の Restricted Actions）。各タスクの Commit ステップは承認後に走らせる
- ビルド: `./scripts/build_debug_stable.sh`。**Xcode 16.4 ではコンパイルできない**。Xcode 26 が必要
- プローブ実行: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
- ベースライン実測値（main @ d019df1f で計測）: shim unit tests 101 passed / Swift logic probe 246 passed
- `.github/workflows/ci.yml` の `EXPECTED_ASSERTIONS` は当時 `246`（現在は 265）。**推測で書き換えず、プローブの実測値をそのまま入れる**
- ~~ユーザーのドラッグ以外で行もペインも動かさない~~ — **この制約は破棄された。** 実機で破綻し、ペイン割り当て時に行を動かす `moveRowFollowingPaneAssignment` が入った。現行の原則は spec の「原則」節を読むこと

## File Structure

| ファイル | 役割 | 変更 |
|---|---|---|
| `Sources/Canopy/SessionStore.swift` | ペイン状態の唯一の所有者 | `movePanesFollowingDrag(draggedIds:)` を追加、`moveOpenSessions` から呼ぶ |
| `Sources/Canopy/Sidebar.swift` | サイドバーの行と click ルーティング | `.open` 分岐で `addNewPane` を無視、`bouncePane` を削除 |
| `Sources/Canopy/_SidebarLogicProbe.swift` | DEBUG 専用ロジックテスト | ペインブロックの末尾にアサーション追加 |
| `.github/workflows/ci.yml` | アサーション数の床 | `EXPECTED_ASSERTIONS` を実測値へ引き上げ |

---

### Task 1: ドラッグでペインを追従させる

**Files:**
- Modify: `Sources/Canopy/SessionStore.swift`（`moveOpenSessions` は 724-740 行）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`（ペインブロックの閉じ括弧は 2127 行、その直前に追加）
- Modify: `.github/workflows/ci.yml:431`

**Interfaces:**
- Consumes: `SessionStore.panes: [PaneSlot]`（`private(set)`）、`SessionStore.openSessions: [OpenSession]`、`PaneSlot { id: UUID, content: PaneContent, preferredWidth: CGFloat }`、`PaneContent.session(OpenSession.ID)` / `.launcher`（`Equatable`）、`SessionStore.focusedPaneIndex: Int`（`private(set)`）、`SessionStore.forceSetPaneWidth(at:to:)`、`SessionStore._probeSeedOpenSessions(_:)`
- Produces: `private func movePanesFollowingDrag(draggedIds: [OpenSession.ID])`。`moveOpenSessions` からのみ呼ばれる

- [ ] **Step 1: 失敗するプローブアサーションを書く**

`Sources/Canopy/_SidebarLogicProbe.swift` の 2126 行（`record("openLauncherInNewPane appends launcher pane", ...)` の閉じ括弧）の直後、`do` ブロックを閉じる 2127 行の `}` の直前に挿入する。

```swift

            // MARK: Pane follows sidebar drag
            //
            // Drag is the ONLY thing that moves a pane. Only the dragged
            // session's pane moves — no global re-sort — so a drag never
            // shuffles panes the user did not touch, and a drifted pane
            // order is never snapped back behind the user's back.
            func dragSession(_ n: String) -> OpenSession {
                OpenSession(origin: .local(cwd), resumeId: "drag-\(n)", title: n, project: "p", status: .live)
            }

            // [A][B][C], drag C above B → [A][C][B]
            let dA = dragSession("A"), dB = dragSession("B"), dC = dragSession("C")
            let storeDrag = SessionStore()
            storeDrag._probeSeedOpenSessions([dA, dB, dC])
            _ = storeDrag.openInNewPane(dA.id)
            _ = storeDrag.openInNewPane(dB.id)
            _ = storeDrag.openInNewPane(dC.id)
            storeDrag.forceSetPaneWidth(at: 0, to: 300)
            storeDrag.forceSetPaneWidth(at: 1, to: 400)
            storeDrag.forceSetPaneWidth(at: 2, to: 500)
            let widthSumBefore = storeDrag.panes.reduce(0) { $0 + $1.preferredWidth }
            storeDrag.moveOpenSessions(fromOffsets: IndexSet(integer: 2), toOffset: 1)
            record("drag reorders panes to follow sidebar",
                   storeDrag.panes.map(\.content)
                   == [.session(dA.id), .session(dC.id), .session(dB.id)])
            record("dragged pane carries its width with it",
                   storeDrag.panes[1].preferredWidth == 500
                   && storeDrag.panes[2].preferredWidth == 400)
            record("drag preserves pane count and total width",
                   storeDrag.panes.count == 3
                   && storeDrag.panes.reduce(0) { $0 + $1.preferredWidth } == widthSumBefore)
            record("focus follows the dragged session, not the slot index",
                   storeDrag.focusedPaneIndex == 1)

            // A(pane) B(no pane) C(pane); drag A below B.
            // Paned relative order is unchanged → panes must not move.
            let nA = dragSession("nA"), nB = dragSession("nB"), nC = dragSession("nC")
            let storeNoop = SessionStore()
            storeNoop._probeSeedOpenSessions([nA, nB, nC])
            _ = storeNoop.openInNewPane(nA.id)
            _ = storeNoop.openInNewPane(nC.id)
            storeNoop.moveOpenSessions(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            record("drag across an unpaned row leaves panes alone",
                   storeNoop.openSessions.map(\.id) == [nB.id, nA.id, nC.id]
                   && storeNoop.panes.map(\.content)
                   == [.session(nA.id), .session(nC.id)])

            // Dragging a row that has no pane at all.
            let uA = dragSession("uA"), uB = dragSession("uB"), uC = dragSession("uC")
            let storeUnpaned = SessionStore()
            storeUnpaned._probeSeedOpenSessions([uA, uB, uC])
            _ = storeUnpaned.openInNewPane(uA.id)
            _ = storeUnpaned.openInNewPane(uB.id)
            storeUnpaned.moveOpenSessions(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            record("dragging an unpaned row never touches panes",
                   storeUnpaned.panes.map(\.content)
                   == [.session(uA.id), .session(uB.id)])

            // [A][launcher][B]; drag B above A. The launcher has no sidebar
            // row, so it must hold its slot index while the sessions swap
            // around it.
            let lA = dragSession("lA"), lB = dragSession("lB")
            let storeLaunch = SessionStore()
            storeLaunch._probeSeedOpenSessions([lA, lB])
            _ = storeLaunch.openInNewPane(lA.id)
            _ = storeLaunch.openLauncherInNewPane()
            _ = storeLaunch.openInNewPane(lB.id)
            storeLaunch.moveOpenSessions(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            record("launcher pane holds its index while sessions reorder",
                   storeLaunch.panes.map(\.content)
                   == [.session(lB.id), .launcher, .session(lA.id)])

            // Drift: panes [C][A] while the sidebar reads A, B, C.
            // Dragging the unpaned B must NOT snap panes into sidebar order.
            let fA = dragSession("fA"), fB = dragSession("fB"), fC = dragSession("fC")
            let storeDrift = SessionStore()
            storeDrift._probeSeedOpenSessions([fA, fB, fC])
            _ = storeDrift.openInNewPane(fC.id)
            _ = storeDrift.openInNewPane(fA.id)
            storeDrift.moveOpenSessions(fromOffsets: IndexSet(integer: 1), toOffset: 3)
            record("drag never snaps drifted panes into sidebar order",
                   storeDrift.openSessions.map(\.id) == [fA.id, fC.id, fB.id]
                   && storeDrift.panes.map(\.content)
                   == [.session(fC.id), .session(fA.id)])
```

- [ ] **Step 2: ビルドして失敗を確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -20
```

Expected: ビルド成功、プローブが `FAIL drag reorders panes to follow sidebar` を含む複数の FAIL を出し、`--- N passed, M failed ---` の M が 0 でなく、終了コードが 0 以外。

`moveOpenSessions` は現状ペインに触らないので、順序を変える 3 件（drag reorders / dragged pane carries its width / focus follows）と launcher の 1 件が落ちる。no-op 系の 3 件は現状でも通る（実装後も通り続けることが本来の意味）。

- [ ] **Step 3: helper を実装する**

> **この節のコードは出荷版ではない。** レビュー（PR #126）で 2 つの欠陥が見つかり、実装は書き換わった。**コピー元にしないこと** — 出荷版は行順への単純ソート。`SessionStore.syncPaneOrderToRows` と spec の「変更点 2」を読む。
>
> 1. **複数行ドラッグ。** 下のループはドラッグされたペインを 1 つずつ動かすが、最初の挿入が後のランク計算の前提をずらす。`[A][B][C][D]` の行 B,C を D の後ろへ動かすと、行は `A,D,B,C` になるのにペインは `A,B,D,C` になった。次の版はドラッグ対象を全部抜いてから挿し直す形にしたが、それも捨てられた。
> 2. **フィルタで隠れたペイン。** 下の `sessionSlots` は全 session ペインを対象にするので、行がフィルタで隠れているペインまで動く。行側の `reorderPreservingHidden` は隠れた行を固定するので、両者が非対称になりフィルタを外すと順序のズレが露見した。次の版は隠れたペインを launcher ペインと同じく固定したが、それが逆にペインなし行との組み合わせを壊した。

`Sources/Canopy/SessionStore.swift` の `moveOpenSessions`（740 行の閉じ括弧）の直後に追加する。

```swift

    /// Move the just-dragged sessions' panes to follow the new
    /// `openSessions` order. ONLY the dragged sessions' panes move — there
    /// is deliberately no global re-sort. A drag must never shuffle a pane
    /// the user did not touch, and a pane order that has drifted from the
    /// sidebar (plain-clicking an unpaned session into a pane does that)
    /// must never snap back on an unrelated drag.
    ///
    /// The unit of movement is the whole `PaneSlot`, so `preferredWidth`
    /// travels with the session: the total is unchanged, the window is not
    /// resized, and each WKWebView keeps its width and merely shifts x —
    /// no reflow, no chat scroll drift. Moving the slot (rather than
    /// swapping `content` between fixed slots) also keeps
    /// `Detail.swift`'s `SessionContainer(...).id(session.id)` paired with
    /// the same subtree, so `ForEach` sees a move instead of a teardown.
    ///
    /// Launcher panes have no sidebar row, so they hold their slot index;
    /// session panes permute only among the slots they already occupy.
    /// `draggedIds` must arrive in final `openSessions` order so a
    /// multi-row drag is deterministic.
    private func movePanesFollowingDrag(draggedIds: [OpenSession.ID]) {
        guard !panes.isEmpty else { return }
        let focusedSlotId = panes.indices.contains(focusedPaneIndex)
            ? panes[focusedPaneIndex].id
            : nil

        // Slot positions session panes occupy, left to right.
        let sessionSlots = panes.indices.filter {
            if case .session = panes[$0].content { return true }
            return false
        }
        guard sessionSlots.count > 1 else { return }

        var ordered = sessionSlots.map { panes[$0] }
        let panedIds: Set<OpenSession.ID> = Set(ordered.compactMap { slot in
            if case .session(let id) = slot.content { return id }
            return nil
        })
        // Ranks the paned sessions hold in the post-drag sidebar order.
        let sidebarRanking = openSessions.map(\.id).filter { panedIds.contains($0) }

        for draggedId in draggedIds {
            guard let from = ordered.firstIndex(where: { $0.content == .session(draggedId) }),
                  let to = sidebarRanking.firstIndex(of: draggedId),
                  to != from,
                  ordered.indices.contains(to)
            else { continue }
            let slot = ordered.remove(at: from)
            ordered.insert(slot, at: to)
        }

        for (slotPos, slot) in zip(sessionSlots, ordered) {
            panes[slotPos] = slot
        }

        // Focus tracks the session, not the slot index.
        if let focusedSlotId,
           let newIndex = panes.firstIndex(where: { $0.id == focusedSlotId }) {
            focusedPaneIndex = newIndex
        }
    }
```

- [ ] **Step 4: `moveOpenSessions` から呼ぶ**

`Sources/Canopy/SessionStore.swift:724` の `moveOpenSessions` を書き換える。`visibleIds` はドラッグ前の可視順なので、`fromOffsets` の解決は並べ替えより前に行う。

```swift
    func moveOpenSessions(fromOffsets: IndexSet, toOffset: Int) {
        let visibleIds = visibleRows.compactMap { row -> UUID? in
            if case .open(let s) = row { return s.id }
            return nil
        }
        // Resolve which sessions were dragged BEFORE the reorder: the
        // offsets are in pre-drag visible-row coordinates.
        let draggedIds = fromOffsets.compactMap { off -> UUID? in
            visibleIds.indices.contains(off) ? visibleIds[off] : nil
        }
        let masterIds = openSessions.map(\.id)
        let newOrder = Self.reorderPreservingHidden(
            master: masterIds,
            visible: visibleIds,
            fromOffsets: fromOffsets,
            toOffset: toOffset
        )
        guard newOrder != masterIds else { return }
        let byId = Dictionary(uniqueKeysWithValues: openSessions.map { ($0.id, $0) })
        openSessions = newOrder.compactMap { byId[$0] }
        // Apply in final sidebar order so a multi-row drag is deterministic.
        let draggedSet = Set(draggedIds)
        movePanesFollowingDrag(
            draggedIds: openSessions.map(\.id).filter { draggedSet.contains($0) }
        )
        logger.info("moveOpenSessions from=\(fromOffsets.map(String.init).joined(separator: ","), privacy: .public) to=\(toOffset)")
    }
```

- [ ] **Step 5: ビルドしてプローブが通ることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -12
```

Expected: `--- N passed, 0 failed ---`。N は 246 + 追加したアサーション数。

- [ ] **Step 6: `EXPECTED_ASSERTIONS` を実測値へ引き上げる**

Step 5 が出力した N をそのまま `.github/workflows/ci.yml:431` に書く。推測値を書かない。

```yaml
          EXPECTED_ASSERTIONS: <Step 5 が出力した N>
```

- [ ] **Step 7: 実機でスクロール位置が保たれることを確認する**

これは自動テストで代替できない。`ForEach` の要素移動が SwiftUI 上で再マウントにならないことを目視で確かめる唯一の手段。

```bash
open /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap/build/Build/Products/Debug/Canopy.app
```

手順: 2 つのセッションをそれぞれ別ペインで開く → 両方のチャットを途中までスクロールする → サイドバーで片方の行をもう片方の上下へドラッグする。

確認すること:
- ペインの左右位置が入れ替わる
- 各ペインの幅が入れ替わり先へ付いていく（ウィンドウ幅は変わらない）
- **両方のチャットのスクロール位置が動かない**
- webview が再読み込みされない（チャット内容が一瞬消えない）

スクロールが飛ぶ場合は再マウントが起きている。その場合は Step 3 の doc コメントに実測結果を追記した上で報告する。

- [ ] **Step 8: Commit（ユーザーの承認後）**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
jj describe -m "Follow sidebar drag with pane position

- Add SessionStore.movePanesFollowingDrag: moves only the dragged
  sessions' PaneSlots, no global re-sort, so an unrelated drag never
  shuffles panes and a drifted order is never snapped back
- Move whole PaneSlots so preferredWidth travels with the session:
  total width unchanged, no window resize, no WKWebView reflow
- Launcher panes hold their slot index; session panes permute only
  among the slots they occupy
- Focus tracks the session by PaneSlot.id, not by index
- Probe: 8 assertions covering reorder, width transport, no-op cases,
  launcher pinning, and drift preservation

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 2: open 行の Cmd+click を素のクリックとして扱う

**Files:**
- Modify: `Sources/Canopy/Sidebar.swift:323-347`（`handleRowClick` の `.open` 分岐と `bouncePane`）
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`（Task 1 で追加したブロックの末尾）
- Modify: `.github/workflows/ci.yml:431`

**Interfaces:**
- Consumes: `SessionStore.openInFocusedPane(_:)`
- Produces: なし（`bouncePane(forSessionId:)` が消える）

**注意:** `handleRowClick` は View の private メソッドでプローブから到達できない。Step 1 のアサーションは `openInFocusedPane` の帰結（ペインが増えないこと）を固定するもので、ルーティング自体は Step 5 の手動確認で担保する。

- [ ] **Step 1: プローブアサーションを追加する**

Task 1 で追加したブロックの末尾（`record("drag never snaps drifted panes into sidebar order", ...)` の直後）に追加する。

```swift

            // An open row's click — Cmd held or not — routes through
            // openInFocusedPane. Cmd must never grow a pane from a row
            // that is already open: that pushes it to the right end, which
            // reads as the sidebar moving things on its own.
            let cA = dragSession("cA"), cB = dragSession("cB")
            let storeCmd = SessionStore()
            storeCmd._probeSeedOpenSessions([cA, cB])
            _ = storeCmd.openInNewPane(cA.id)
            storeCmd.openInFocusedPane(cB.id)
            record("open-row click replaces the focused pane, never adds one",
                   storeCmd.panes.count == 1
                   && storeCmd.panes[0].content == .session(cB.id))
```

- [ ] **Step 2: `.open` 分岐を書き換える**

`Sources/Canopy/Sidebar.swift:325-330` を置き換える。

```swift
        case .open(let session):
            // Cmd is deliberately ignored on open rows: Cmd+click behaves
            // exactly like a plain click. openInFocusedPane already focuses
            // the session's existing pane when it has one, and loads it into
            // the focused pane when it does not. Growing a NEW pane from an
            // already-open row would append it at the right end regardless
            // of where the row sits, which reads as the sidebar rearranging
            // itself. Panes are now born only with new sessions, where the
            // row append and the rightmost pane append coincide.
            store.openInFocusedPane(session.id)
```

`addNewPane` パラメータは `.closedLocal` / `.closedCloud` 分岐が使い続けるので残す。

- [ ] **Step 3: `bouncePane` を削除する**

`Sources/Canopy/Sidebar.swift:349-357` の `bouncePane(forSessionId:)` を丸ごと削除する。Step 2 で唯一の呼び出し元が消えるため。

削除前に呼び出し元が本当に無いことを確認する:

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
grep -rn "bouncePane" Sources/
```

Expected（削除前）: 定義 1 件のみ。呼び出しがまだ出るなら Step 2 が未完了。

- [ ] **Step 4: ビルドしてプローブが通ることを確認する**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -12
```

Expected: `--- N passed, 0 failed ---`、警告なし（未使用メソッドが残っていれば Swift が警告を出す）。

- [ ] **Step 5: 実機で挙動を確認する**

```bash
open /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap/build/Build/Products/Debug/Canopy.app
```

確認すること:
- 開いているセッションの行を Cmd+click → ペインが増えない。そのセッションが既にペインにあればそこへフォーカスが移り、なければフォーカス中のペインに読み込まれる。素のクリックと区別がつかない
- 閉じたセッションの行を Cmd+click → 従来通り新しいペインで開く（変更していない経路）
- サイドバーの New Session ボタンを Cmd+click → 従来通り新しいペインにランチャーが出る（変更していない経路）

- [ ] **Step 6: `EXPECTED_ASSERTIONS` を実測値へ更新する**

Step 4 が出力した N を `.github/workflows/ci.yml:431` に書く。

- [ ] **Step 7: Commit（ユーザーの承認後）**

```bash
cd /Users/hiko/repos/Personal/Canopy/.claude/worktrees/pane-swap
jj describe -m "Treat Cmd+click on an open sidebar row as a plain click

- Cmd no longer grows a pane from an already-open session: that
  appended at the right end regardless of the row's position, which
  reads as the sidebar rearranging itself
- Panes are now born only with new sessions, where the openSessions
  append and the rightmost pane append coincide
- Remove bouncePane, dead once the .open branch stops calling it
- Raise EXPECTED_ASSERTIONS to the measured probe count

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
```

---

## Self-Review

**Spec coverage**

| spec の項目 | 対応 |
|---|---|
| 変更点 1（open 行の Cmd+click を単なるクリック扱い） | Task 2 Step 2 |
| `bouncePane` 削除 | Task 2 Step 3 |
| 変更点 2（ドラッグでペイン追従） | Task 1 Step 3-4 |
| ~~ドラッグされたペインだけ動かす~~ | **破棄**。出荷版は全 session ペインを行順にソートする |
| launcher ペインの index 固定 | Task 1 Step 3、テストは launcher ケース |
| 複数行ドラッグの決定性 | Task 1 Step 4（最終順で適用）。実装はレビューで書き換え — Step 3 の注記参照 |
| `focusedPaneIndex` がセッション追従 | Task 1 Step 3、テストあり |
| 幅がスロットごと移動 | Task 1 Step 3、テストあり |
| `normalizePaneWeightsToVisualWidths` / `schedulePaneResize` を呼ばない | Task 1 Step 3（呼んでいない）、総和不変テストで固定 |
| 再マウント確認 | Task 1 Step 7（手動） |
| `EXPECTED_ASSERTIONS` 引き上げ | Task 1 Step 6 / Task 2 Step 6 |

**spec から落としたテスト 1 件:** 「フィルタで一部の open 行が隠れている状態でも、隠れた行がペイン順に影響しない」。`movePanesFollowingDrag` は並べ替え後の `openSessions` しか読まず、可視座標からマスター座標への写像は既存の `reorderPreservingHidden`（プローブに 6 アサーション既存、`_SidebarLogicProbe.swift:918-943`）が担保している。……という当時の判断は**誤りだった**。出荷版はフィルタ絡みのテストを 2 件持っている。

**Placeholder scan:** なし。全ステップに実際のコードとコマンドが入っている。

**Type consistency:** `movePanesFollowingDrag(draggedIds: [OpenSession.ID])` は Task 1 Step 3 で定義し Step 4 で呼ぶ。`OpenSession.ID` は `UUID`（`moveOpenSessions` の既存コードが `UUID?` を使っているのと同一）。`PaneContent` の `Equatable` 準拠は `PaneSlot.swift` で宣言済みなので `$0.content == .session(draggedId)` と `panes.map(\.content) == [...]` の両方が成立する。`forceSetPaneWidth(at:to:)` は `SessionStore.swift:933` に既存（`PaneWindowSizer` のフォールバックが使用）。
