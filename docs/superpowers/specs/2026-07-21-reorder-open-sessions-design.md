# Reorder Open Sessions in Sidebar — Design

Date: 2026-07-21
Status: Approved

## Goal

Let the user drag-and-drop rows within the sidebar's "Open" section to reorder
open sessions. Closed rows (Recents / Cloud) stay date-sorted and non-draggable.

## Current State

- `SessionStore.openSessions` is the master insertion-ordered array.
- `SidebarRow.sorted(_:)` preserves that order for the open block (browser-tab
  convention: append at bottom).
- `Sidebar.swift` renders the open block via `ForEach(openRows, id: \.id)`
  inside `Section("Open")`.
- Everything downstream derives from array order: Cmd+1..9 switching,
  `closeSession`'s "focus the row that took the closed tab's slot" logic,
  WebView swap targeting. No separate order state exists anywhere.

## Design

### Interaction

Standard SwiftUI `List` row drag: attach `.onMove` to the open-block `ForEach`
only. macOS renders the drag + drop-indicator UI for free. Closed sections get
no `.onMove`, so they remain non-draggable.

**Discovered during implementation (2026-07-22):** any tap gesture on the row
(`.onTapGesture` AND `.simultaneousGesture(TapGesture())`) claims mouse-down
and prevents the List's row-drag from ever starting on macOS (FB7367473
family). The sidebar's whole-row click handler therefore moved off gestures
for open rows: the `List` gets a `selection:` binding that always reads `nil`
(so the system never paints its own selection highlight) and whose setter is
the click handler. Closed rows are `.selectionDisabled` and keep the plain
tap gesture — they don't drag, and routing them through selection would also
fire on right-click.

### Data flow

1. **`Sidebar.swift`** — add `.onMove { from, to in store.moveOpenSessions(...) }`
   to the `ForEach(openRows)`.
2. **`SessionStore.moveOpenSessions`** — the one subtle part: `visibleRows` is
   filter-applied, so when the filter hides some open rows (e.g. a status
   filter), visible offsets ≠ `openSessions` indices. The handler therefore
   works in IDs, not offsets:
   - From the visible open rows, resolve the dragged session's `UUID` and the
     `UUID` of the visible row it lands before (nil = end of visible list).
   - Reorder the master `openSessions` array so the dragged session sits
     immediately before that target's master index. Hidden rows keep their
     relative positions.
3. **No downstream changes** — Cmd+1..9, `closeSession` neighbor-focus, and
   WebView swap all read `openSessions` order and pick up the new order
   automatically.

### Persistence

None. Open sessions don't survive app relaunch, so their order dies with them.
`lastActiveResumeId` and recents ordering are unaffected.

### Edge cases

- Drag with an active filter hiding some open rows: handled by the ID-based
  mapping above.
- Drag a single row onto itself / no-op move: `moveOpenSessions` returns early
  when the order is unchanged.
- Selection is untouched by a move — the selected session stays selected;
  only its Cmd+N index may change (expected, matches browser tabs).

## Testing

Add probe coverage in `_SidebarLogicProbe.swift` (`CANOPY_RUN_LOGIC_PROBE=1`)
for the move-mapping logic, exercised as a pure function:

- Move within a fully visible open block (front, middle, end).
- Move while a filter hides interior open rows — hidden rows keep relative
  order, visible ones land where dropped.
- No-op move leaves the array untouched.

To keep it probe-testable, the reorder core is a pure static helper (array +
dragged id + target id → new array) that `SessionStore.moveOpenSessions` calls.
