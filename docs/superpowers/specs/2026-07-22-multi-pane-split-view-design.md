# Multi-Pane Split View — Design Spec

**Date:** 2026-07-22
**Status:** Draft (pending user review)

## Motivation

Today Canopy shows exactly one session in the detail column at a time. Switching between open sessions is a single WKWebView subview swap (~10–30 ms). Fast, but strictly one-at-a-time — you can only actively drive one session with the keyboard, and cannot see two conversations side by side.

We want to support **actively driving 2–5 sessions in parallel** by opening them as horizontal split panes inside the same window. Each pane accepts keyboard input independently; only the focused pane receives typing.

## Non-goals

- **Recursive / nested splits** (VS Code style). Horizontal columns only.
- **Grid layouts** (2×2, 1+2 stacked). Horizontal only — chat UI benefits from vertical space.
- **Pane persistence across app restart.** Consistent with today's `openSessions` behavior (nothing is restored beyond `lastActiveResumeId`).
- **Drag-reorder of panes.** Deferred; sidebar Cmd+click adds to the right end.
- **Same session in two panes.** One session, one pane at a time (WKWebView owner invariant).
- **Multiple windows.** Single-window sidebar shell stays as-is.

## User model

- Open a second (third, fourth, fifth) session as a new pane with **Cmd+click** on a sidebar row or Launcher launch button.
- Plain **click** on a sidebar row replaces the *focused* pane's content — matches today's single-pane behavior.
- Adding a pane **grows the window horizontally** to keep the existing panes at their current width. Closing a pane **shrinks the window back**. Symmetric.
- If the window can't grow (screen edge), the panes fall back to sharing the available width equally.
- Focus moves with clicks inside a pane, or via **Cmd+Opt+← / →** (wraps).
- Max **5 panes** total.

## Prerequisite work (bundled into this spec)

Multi-pane implies each pane is narrower than today's default window. The current per-session status bar overflows below ~600 pt, which would look broken as soon as a second pane is added on most screens. Two changes go together:

1. **Move the shared rate-limit UI out of every per-pane status bar** into a new "Account" section at the bottom of the sidebar. Rate limits are account-scoped, not session-scoped, and `SharedRateLimitData` already models them cross-session.
2. **Make the per-pane status bar responsively collapse** (icon-only + tooltips) so it stays readable at narrow widths.

These are Phase 0 of the implementation and must land before Phase 1 (multi-pane machinery) becomes usable.

---

## Model additions

`SessionStore` gains:

```swift
var panes: [OpenSession.ID] = []        // ordered left → right
var focusedPaneIndex: Int = 0
```

Invariants:

- Every `panes` entry must exist in `openSessions`. Panes are a subset of open sessions.
- No `OpenSession.ID` appears in `panes` more than once.
- `focusedPaneIndex` is always a valid index into `panes` (or 0 if empty — the empty state is only the transient app-just-launched moment before the first pane fills in).
- `panes.count` is capped at `absoluteCap = 5`.
- When `panes` is empty and the user selects a session, that session becomes `panes = [PaneSlot(id, preferredWidth: 800)]`, `focusedPaneIndex = 0` (single-pane default). 800 pt is the initial preferred width — every subsequent pane addition inherits from the current focused pane instead.

Per-pane view-model state (owned by `OpenSession` today, unchanged):

- `shim: ShimProcess`
- `webView: WKWebView`
- `statusBar: StatusBarData`
- `connection`, `isThinking`, `isAsking`, `isWaiting`, `title`, `project`, ...

Additionally, each pane needs an **intrinsic preferred width**. This lives on a new lightweight per-pane record rather than on `OpenSession` (a session's width shouldn't be baked into the session itself — same session opened again later shouldn't remember its "last width in a pane"):

```swift
struct PaneSlot {
    let sessionId: OpenSession.ID
    var preferredWidth: CGFloat   // default 800 on first open; inherited from focused pane on add
}
var panes: [PaneSlot] = []
```

## Layout

`Detail.swift` today returns a single `SessionContainer`. New shape:

```
HStack(spacing: 0) {
    ForEach(panes) { pane in
        SessionContainer(session: openSessions[pane.sessionId])
            .frame(width: pane.preferredWidth)
            .overlay(focusIndicatorBorder(active: pane.id == panes[focusedPaneIndex].id))
        if not last:
            PaneDivider(leftWidth: $panes[i].preferredWidth,
                        rightWidth: $panes[i+1].preferredWidth)
    }
}
```

Concretely:

- Each pane is the existing `SessionContainer` (WebView + StatusBar + SubagentList + overlays) wrapped in a thin per-pane header strip (see below).
- Divider between panes is 1 pt visual line with a wider (8 pt) invisible drag target.
- Focus indicator: 2 pt accent-colored border around the focused pane, 0 pt on others. Transition animates 100 ms.

### Per-pane header strip

Today the session's title and project path live in the window's `navigationTitle` / `navigationSubtitle`. Those slots hold one string, which no longer works when N sessions are visible. Each pane grows a 24 pt tall header:

- **Left:** session title (truncated with tail ellipsis).
- **Middle-left:** small project label (dimmed).
- **Right:** close X button, visible only on pane hover.

The window's `navigationTitle` / `navigationSubtitle` follow the **focused pane** — the macOS convention that the window title reflects the active document. Switching focus updates the window title immediately.

When `panes.count == 1` the header strip is still drawn (visual consistency + close button parity), but the strip's own title is redundant with the window title. That's fine — the extra 24 pt is a small price for a single always-consistent layout.

### Window sizing

Let:

- `sidebarW` = current sidebar column width
- `paneW_i` = each pane's preferred width
- `dividerW` = 1 pt × (paneCount − 1)
- `targetW = sidebarW + Σ paneW_i + dividerW`
- `screenMaxW` = `NSScreen.main.visibleFrame.width` (or the current screen's)

**On pane add (Cmd+click):**

1. New pane inherits focused pane's `preferredWidth` (default 800 pt on first open).
2. Compute `targetW` after append.
3. If `targetW ≤ screenMaxW` → set window frame width to `targetW`, animated 200 ms ease-out. Preserve pane widths.
4. Else → set window frame width to `screenMaxW`, and re-share the resulting detail column equally across all panes (each pane's `preferredWidth` is updated to the equal share). This is the "fallback split" — user's earlier per-pane widths are overwritten in this branch.

**On pane close:**

1. Remove pane from `panes`.
2. Compute `targetW`.
3. Set window frame width to `targetW`, animated 200 ms ease-out. Remaining panes keep their widths.

**On divider drag:**

- Adjusts the two adjacent panes' `preferredWidth`. Sum of the two stays constant, so window width does not change.
- Hard floor: each pane cannot drag below **100 pt** (safety only; below this the UI is objectively broken and the user gains nothing).
- No ceiling other than the two-pane sum.

**On window resize by the user:**

- Delta is distributed proportionally across pane preferredWidths (each pane changes by `delta × paneW_i / Σ paneW_i`).
- Same 100 pt floor per pane; overflow delta stays on the window edge (leaves a small gap, or contributes to the neighbor if a pane hits the floor).

**On screen change (external display connected / disconnected):**

- Existing panes are preserved as-is even if `targetW > screenMaxW`. The user can drag dividers or close panes.
- Only *new pane additions* are affected — they take the "cap and equal-share" fallback branch.

### Max panes

```
maxPanes = absoluteCap = 5
```

No screen-width term. The window's ability to accommodate the panes is enforced by the fallback branch above (equal share when we can't grow), not by refusing to add.

Adding when `panes.count == 5` bounces (no-op) and shows a transient "Maximum 5 panes" hint in the focused pane's status bar for ~1 s.

---

## Sidebar row semantics

Today's `List(selection:)` uses a "binding that always returns nil" trick to preserve drag+`.onMove` while still routing single-tap → session selection. That mechanism stays but the selection setter's behavior changes:

- **Plain click on a session row**:
  - Session already in a pane → move focus to that pane (no-op on `panes`).
  - Session not in any pane → replace focused pane's session (if session was closed, promote it to `openSessions` first).
- **Cmd+click on a session row** (`.command` modifier detected on the click):
  - Session already in a pane → move focus to that pane, bounce hint (nothing to add).
  - `panes.count == 5` → bounce.
  - Else → promote to `openSessions` if needed, append to `panes`, focus it. Trigger window grow.
- **Plain click on the Launcher row**:
  - Replace focused pane with the Launcher view.
- **Cmd+click on the Launcher row**:
  - Append a new Launcher pane, focus it, grow window.
- **Right-click "Hide from sidebar"**:
  - Disabled (grayed) for sessions currently in `openSessions` (which includes any pane). Only closed sessions can be hidden.

### Sidebar row highlighting

Today: single selected row highlighted with system accent.

New two-tier scheme:

- Rows for sessions in **any** pane → **weak highlight** (background tinted lightly with accent, no border).
- Row for the session in the **focused** pane → **strong highlight** (system-accent background, matches today's selected style).
- Sidebar shows up to 5 weak-highlighted rows plus one of them strong-highlighted.

Drag+`.onMove` on open-session rows continues to work — the highlight is a display concern, unrelated to the selection binding's drag interference.

---

## Sidebar Account section (Phase 0)

New sticky section at the bottom of the sidebar, below Recents:

```
┌──────────────────┐
│ Launcher         │
│ ──────────────── │
│ Open sessions    │
│  • sess1         │
│  • sess2         │
│                  │
│ Recents          │
│  · older…        │
│  · …             │
│                  │
├──────────────────┤   ← always visible bottom bar
│ Account          │
│  5hr ▓▓░░  25%   │  26m
│  Wk  ▓▓▓▓ 53%    │  3d
└──────────────────┘
```

- Reads from the existing `SharedRateLimitData` (already cross-session).
- Two rows: 5-hour limit and weekly limit. Each shows a progress bar + percentage + reset countdown.
- Reset countdowns tick using the same TimelineView pattern used elsewhere.
- Section stays visible even when the sidebar list is scrolled (sticky footer).
- Hidden entirely if `SharedRateLimitData` has no data yet (fresh install, no session ever launched).

---

## Per-pane status bar (Phase 0)

Trim shared items from every per-pane status bar:

**Removed** (moved to sidebar Account):
- 5-hour rate limit bar + countdown
- Weekly rate limit bar + countdown

**Kept per-pane** (all session-scoped):
- Model badge (e.g. `Opus 4.7`)
- CLI version (`v2.1.217`) — kept per-pane because remote sessions can differ
- Branch indicator (`main (empty)`)
- Context usage (`132K/923K` + percentage bar)
- Session usage counter (`⏱ 108`)
- Remote host indicator (only when present)

### Responsive collapse

Priority order for progressive collapse (drop rightmost first when width tightens):

1. Session usage counter (⏱ 108) — drop first
2. CLI version — collapse to icon + tooltip
3. Branch indicator — truncate branch name, then collapse to icon + tooltip
4. Context usage numeric (keep the bar visually) — drop the `132K/923K` label first, then leave the percentage
5. Model badge — never drop (most identity-critical)

At extreme narrow widths (below ~250 pt), the status bar reduces to just the model badge + a "…" that opens the full set in a popover on click.

Actual break-point widths are tuned during Phase 0 implementation against real DOM widths reported by `InputWidthProbe`. `StatusBarData.chatInputWidth` already tracks per-pane width — the new responsive layout reads from it.

---

## Pane lifecycle

### Add (Cmd+click sidebar row / Cmd+click Launcher launch button)

1. If session is already in a pane → focus that pane, bounce.
2. If `panes.count == 5` → bounce, show "Maximum 5 panes" hint.
3. Ensure session is in `openSessions` (spawn shim if newly opened).
4. Append `PaneSlot(sessionId, preferredWidth: currentFocusedPane.preferredWidth)` to `panes`.
5. Compute `targetW`, grow window (or fall back to equal-share).
6. Set `focusedPaneIndex = panes.count - 1`.

### Close (Cmd+W with `panes.count > 1`, or X on pane header)

1. Remove `panes[focusedPaneIndex]`.
2. Compute `targetW`, shrink window.
3. `focusedPaneIndex = max(0, focusedPaneIndex - 1)`.
4. Underlying `OpenSession` stays in `openSessions` — closing the pane does not close the session. The sidebar row remains and can be re-focused / re-added.

If `panes.count == 1` when Cmd+W fires, fall through to today's Cmd+W behavior (close focused session, or fall back to closing the focused non-main window, or the main window).

### Focus switch

- Mouse: any click landing inside a pane's `SessionContainer` bounds sets `focusedPaneIndex` to that pane. WKWebView first-responder handoff follows.
- **Cmd+Opt+←** : `focusedPaneIndex = (i - 1 + count) mod count` — wraps.
- **Cmd+Opt+→** : `focusedPaneIndex = (i + 1) mod count` — wraps.

### Cmd+1..9

- Semantics extended: switch **focused pane's content** to the Nth open session (in sidebar-visible order, same order as today's Cmd+1..9).
- If Nth session is already in another pane → focus that pane instead (no swap). Matches the "one session, one pane" invariant.

### Cmd+N (new session)

- Replace focused pane with the Launcher view.

### Cmd+O (open folder)

- Focused pane → folder picker → launch new session in that pane after selection.

### Right-click menu on pane header (v1)

- Close pane
- (Future: reorder, move to another window, etc. — YAGNI for v1)

### Pane close button

The X button on the per-pane header strip is a hover-only affordance on the right edge of the strip. Clicking it triggers the same close flow as Cmd+W (with `panes.count > 1`). When `panes.count == 1` the X on the sole pane's header is hidden — closing the last pane belongs to Cmd+W / window close.

---

## Edge cases

1. **Focused pane's session ends** (shim crash, session closed via sidebar UI, remote SSH disconnect that terminates the CLI):
   - Pane auto-closes → same flow as manual close (window shrinks, focus shifts left).
   - No modal toast; sidebar + status bar already communicate the state clearly.

2. **Session hidden from sidebar while in a pane**:
   - Not reachable — "Hide from sidebar" is disabled for sessions in `openSessions` (see Sidebar semantics).

3. **Cloud session teleport**:
   - Target: focused pane. Cmd+click on a cloud row adds a new pane and teleports into it.
   - During teleport the target pane shows its existing spawning overlay; other panes keep running.
   - `SessionStore.teleportingCloudId` serialization stays as today (only one teleport at a time globally).

4. **Screen change** (external display connect/disconnect, window moved between screens):
   - Existing panes preserved even if they no longer fit — the window keeps its width or clamps to the new screen, whichever the system decides.
   - Only pane *additions* switch to the equal-share fallback when the new screen can't accommodate the target width.

5. **Sidebar collapse** (`NavigationSplitView` sidebar hidden):
   - Detail column widens; panes keep their `preferredWidth`. Extra space becomes trailing empty space until the user drags a divider or the window is resized.

6. **Local + remote session mix in panes**:
   - Fully supported. Each pane is an independent shim + WebView. No cross-pane state.

7. **IME state during focus switch**:
   - Each WKWebView owns its own IME state; macOS handles handoff on first-responder change. No custom bridging needed.

8. **Pane focus indicator vs system window focus**:
   - The 2 pt border stays on when the app window loses focus (so returning to the app remembers where you were typing).
   - When the app is active but no pane has been clicked yet after launch, the leftmost pane is focused.

9. **Drag reorder of open-session rows in sidebar**:
   - Continues to work (existing `.onMove` on sidebar). Reordering affects Cmd+1..9 index but not pane order.

10. **New session (Cmd+N / Launcher launch) when panes are full**:
    - `panes.count == 5`, Cmd+N inside focused pane → replaces the focused pane with Launcher (fine, no new pane created).
    - `panes.count == 5`, Cmd+click Launcher launch button → bounces (max reached).

---

## Implementation phasing

**Phase 0 — Prerequisite (separate PR)**
- Move rate-limit UI from per-pane status bar to sidebar Account section.
- Implement per-pane status bar responsive collapse.
- Ships as a standalone improvement — valuable even at 1 pane on narrow windows.

**Phase 1 — Multi-pane machinery**
- `PaneSlot` model and `panes` / `focusedPaneIndex` on `SessionStore`.
- `Detail.swift` HStack layout with dividers + focus indicator.
- Window grow / shrink logic tied to pane add / close.
- Sidebar row click / Cmd+click semantics + two-tier highlighting.
- Keyboard shortcuts (Cmd+Opt+←/→, Cmd+W adaptation, Cmd+1..9 semantics).
- Pane close via X button on pane header.
- Bounce animations + "Max panes" hint.

Phase 1 depends on Phase 0 being merged; the multi-pane UI is only usable once status bars can survive narrow widths.

---

## Out of scope / future

- Nested / recursive splits (VS Code style)
- Grid layouts (2×2, 1+2 stacked)
- Pane persistence across app restart
- Pane drag-reorder
- Same session in multiple panes (mirrored view)
- Multi-window multi-pane (one window can have panes, additional windows would still be one-per-window)
- Cross-pane operations (sync scroll, "run this prompt in all panes", etc.)
- Right-click menu additions beyond "Close pane"
