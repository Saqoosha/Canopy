# Reorder Open Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag-and-drop reordering of rows in the sidebar's "Open" section, with the master `openSessions` array as the single source of order.

**Architecture:** A pure static helper (`SessionStore.reorderPreservingHidden`) maps a move expressed against the *visible* (filter-applied) open rows back onto the master array, keeping filter-hidden sessions in their relative slots. `SessionStore.moveOpenSessions(fromOffsets:toOffset:)` wraps it; `Sidebar.swift` wires it to `.onMove` on the Open-section `ForEach`. Everything downstream (Cmd+1..9, close-neighbor focus, WebView swap) already derives from `openSessions` order and needs no changes.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15+), probe tests in `_SidebarLogicProbe.swift` (no XCTest target — probes run at launch with `CANOPY_RUN_LOGIC_PROBE=1`).

**Spec:** `docs/superpowers/specs/2026-07-21-reorder-open-sessions-design.md`

## Global Constraints

- Do NOT `git commit` or `git push` until Saqoosha explicitly approves — the commit steps below are executed only after that approval.
- No new files — all edits go into existing `Sources/Canopy/SessionStore.swift`, `Sources/Canopy/Sidebar.swift`, `Sources/Canopy/_SidebarLogicProbe.swift`. Therefore `xcodegen generate` is NOT needed.
- Closed rows (Recents / Cloud sections) must remain non-draggable — do not attach `.onMove` to their `ForEach`es.
- No persistence of the order (open sessions die with the app).
- Comment style: match the surrounding code's `///` doc-comment density.

---

### Task 1: Pure reorder helper + probe tests

**Files:**
- Modify: `Sources/Canopy/SessionStore.swift` (add static helper near the bottom of the class, after `stopCloudPolling()`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift` (add a new test block inside `runAllTests()`, just before the `SubagentTracker` block that starts with the comment `// --- SubagentTracker ---` at ~line 623)

**Interfaces:**
- Produces: `static func reorderPreservingHidden<T: Hashable>(master: [T], visible: [T], fromOffsets: IndexSet, toOffset: Int) -> [T]` on `SessionStore`. Task 2's `moveOpenSessions` calls it with `T == UUID`.

- [ ] **Step 1: Write the failing probe tests**

Add to `_SidebarLogicProbe.swift`, inside `runAllTests()`, immediately before the `// --- SubagentTracker ---` comment:

```swift
        // --- Open-session reorder (drag & drop) ---
        // Pure mapping: a move expressed against the visible (filtered) open
        // rows is applied to the master array; hidden rows keep their slots.
        record("reorder: full visible, move first to end",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 0), toOffset: 3)
                   == ["B", "C", "A"])
        record("reorder: full visible, move last to front",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 2), toOffset: 0)
                   == ["C", "A", "B"])
        record("reorder: hidden interior rows keep their slots",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "h1", "B", "h2", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 2), toOffset: 0)
                   == ["C", "h1", "A", "h2", "B"])
        record("reorder: no-op move returns master unchanged",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "h1", "B"], visible: ["A", "B"],
                   fromOffsets: IndexSet(integer: 1), toOffset: 1)
                   == ["A", "h1", "B"])
```

- [ ] **Step 2: Build to verify it fails**

Run:
```bash
cd /Users/hiko/Documents/repos/Personal/Canopy
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```
Expected: BUILD FAILED — `type 'SessionStore' has no member 'reorderPreservingHidden'`.

- [ ] **Step 3: Implement the helper**

Add to `SessionStore.swift`, inside `final class SessionStore`, after `stopCloudPolling()`:

```swift
    // MARK: - Open-session reorder

    /// Pure core of drag-to-reorder. `visible` is the subset of `master`
    /// the sidebar is actually showing (filter-applied), in master order.
    /// The move (`fromOffsets`/`toOffset`, both in visible coordinates —
    /// SwiftUI `.onMove` semantics) is applied to the visible ids, then the
    /// new visible order is written back into the visible slots of `master`.
    /// Hidden ids never change position.
    static func reorderPreservingHidden<T: Hashable>(
        master: [T],
        visible: [T],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [T] {
        var newVisible = visible
        newVisible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard newVisible != visible else { return master }
        let visibleSet = Set(visible)
        var iterator = newVisible.makeIterator()
        return master.map { id in
            visibleSet.contains(id) ? (iterator.next() ?? id) : id
        }
    }
```

- [ ] **Step 4: Build and run the probe to verify it passes**

Run:
```bash
cd /Users/hiko/Documents/repos/Personal/Canopy
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | grep -E "reorder|FAIL|probe"
```
Expected: BUILD SUCCEEDED, then 4 `PASS reorder: …` lines, zero `FAIL` lines, and the summary line.

- [ ] **Step 5: Commit** *(gated on Saqoosha's explicit approval)*

```bash
git add Sources/Canopy/SessionStore.swift Sources/Canopy/_SidebarLogicProbe.swift
git commit -m "Add pure reorder helper for open-session drag & drop

- SessionStore.reorderPreservingHidden maps visible-row moves onto the
  master array, keeping filter-hidden sessions in their slots
- Probe tests: full-visible moves, hidden-interior mapping, no-op

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire `.onMove` into SessionStore and Sidebar

**Files:**
- Modify: `Sources/Canopy/SessionStore.swift` (add `moveOpenSessions` right after `reorderPreservingHidden` from Task 1)
- Modify: `Sources/Canopy/Sidebar.swift:48-54` (the `Section("Open")` block)

**Interfaces:**
- Consumes: `SessionStore.reorderPreservingHidden(master:visible:fromOffsets:toOffset:)` from Task 1.
- Produces: `func moveOpenSessions(fromOffsets: IndexSet, toOffset: Int)` on `SessionStore`, called only by `Sidebar`.

- [ ] **Step 1: Add `moveOpenSessions` to SessionStore**

Add to `SessionStore.swift`, immediately after `reorderPreservingHidden`:

```swift
    /// Handle a drag-reorder from the sidebar's Open section. Offsets are
    /// in visible-row coordinates (the filter may be hiding some open
    /// rows); `reorderPreservingHidden` maps them onto `openSessions`.
    /// Selection is untouched — only row positions (and thus Cmd+1..9
    /// indices) change, matching browser-tab behaviour.
    func moveOpenSessions(fromOffsets: IndexSet, toOffset: Int) {
        let visibleIds = visibleRows.compactMap { row -> UUID? in
            if case .open(let s) = row { return s.id }
            return nil
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
        logger.info("moveOpenSessions from=\(fromOffsets.map(String.init).joined(separator: ","), privacy: .public) to=\(toOffset)")
    }
```

Note: `openSessions` is `private(set)`, so assignment must happen inside this class method (it does).

- [ ] **Step 2: Attach `.onMove` in Sidebar**

In `Sidebar.swift`, change the Open section (currently lines 48–54):

```swift
                if !openRows.isEmpty {
                    Section("Open") {
                        ForEach(openRows, id: \.id) { row in
                            rowView(row)
                        }
                        .onMove { from, to in
                            store.moveOpenSessions(fromOffsets: from, toOffset: to)
                        }
                    }
                }
```

Do NOT touch the `closedSections` `ForEach`es — closed rows stay non-draggable.

- [ ] **Step 3: Build + probe**

Run:
```bash
cd /Users/hiko/Documents/repos/Personal/Canopy
xcodebuild -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED; probe summary with zero FAIL.

- [ ] **Step 4: Manual verification (Saqoosha or session model, not the delegate)**

```bash
open build/Build/Products/Debug/Canopy.app
```
Check: open 3+ sessions → drag a row within "Open" (order changes, drop indicator shows, selection sticks to the same session, Cmd+1..9 follows the new order) → try dragging a Recents row (must not drag) → close the active row after a reorder (focus falls to the row below the closed one in the *new* order).

- [ ] **Step 5: Commit** *(gated on Saqoosha's explicit approval)*

```bash
git add Sources/Canopy/SessionStore.swift Sources/Canopy/Sidebar.swift
git commit -m "Enable drag & drop reordering of open sessions in sidebar

- .onMove on the Open-section ForEach only; closed rows stay fixed
- moveOpenSessions maps visible offsets to the master array via
  reorderPreservingHidden; Cmd+1..9 and close-focus follow automatically

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
