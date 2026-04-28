# Plan: Single-Window Sidebar — Phase A

**Spec:** [2026-04-29-single-window-sidebar.md](../specs/2026-04-29-single-window-sidebar.md)
**Status:** Pre-flight passed (Probe #1 + #2). Ready to implement.

Phase A is the shell conversion: single `Window` + NavigationSplitView, flat sidebar list with open/closed row states, click-to-spawn, hover × close, filter menu, persistence. No live cap; closed → open on click only.

## Sequencing

Five PRs, each builds on the last. The app is launchable and usable after each merge — no half-broken intermediate states. A feature flag (`CANOPY_SIDEBAR=1` env var, then `Settings.useSidebar` UserDefault) keeps the legacy multi-window codepath alive until PR 5 deletes it.

| PR | Scope | Behind flag? |
|----|-------|--------------|
| 1 | `SessionStore` + `OpenSession` model, off-Coordinator state move, no UI change | yes (model used only when flag on) |
| 2 | `Sidebar`, `Detail`, `SessionContainer`, `CanopyApp` Window scene — first usable single-window mode | yes |
| 3 | Filter menu, dedup logic, persistence + restore | yes |
| 4 | Spinner-in-icon, keyboard shortcuts, cloud polling, polish | yes |
| 5 | Flip flag default ON, delete legacy multi-window code, doc updates, ship as 1.12.0 | flag removed |

## PR 1 — Model + state move

Goal: introduce the new types behind a flag, move per-session state off Coordinator. No visible UI change.

### Tasks

1. **`Sources/Canopy/SessionStore.swift`** — new file.
   - `@Observable final class SessionStore` with `openSessions`, `selection`, `recents`, `cloud`, `filter` properties.
   - Stub method bodies: `openNew`, `openLocal`, `openCloud`, `closeSession`, `select`, `refreshRecents`, `refreshCloud`. Real impls land in PR 2/3.
2. **`Sources/Canopy/OpenSession.swift`** — new file.
   - `@Observable final class OpenSession` with all spec fields.
   - `enum Origin`, `enum Status`.
3. **`Sources/Canopy/SidebarRow.swift`** — new file.
   - `enum SidebarRow: Identifiable, Hashable` with `.open`, `.closedLocal`, `.closedCloud`.
   - Computed property `iconName`, `iconStyle`, `title`, `subtitle`, `lastModified`.
4. **`Sources/Canopy/SidebarFilter.swift`** — new file.
   - `struct SidebarFilter: Codable` with `status`, `origin`, `project`, `lastActivity` enums.
   - `apply(to: [SidebarRow]) -> [SidebarRow]`.
5. **Move per-session state from Coordinator/AppState to OpenSession.**
   - `StatusBarData` and `ConnectionState` instances live on `OpenSession`.
   - Update `StatusBarView` and `ConnectionOverlayView` initializers to take an `OpenSession` (compatible with the existing per-window usage by routing through a temporary `OpenSession`-shaped adapter when flag is off).
6. **Unit tests**:
   - `SidebarRow` ordering: open block before closed block, each block sorted by date desc.
   - `SidebarFilter.apply` for each facet.
   - De-dup test (closed local with `teleported-from` removes matching cloud row from output).
7. **No UI changes.** Flag is unused yet; just makes sure the new types compile.

### Verification

- `xcodebuild -scheme Canopy build` succeeds with no warnings.
- Existing tests pass.
- Launching Canopy is bit-identical to today.

## PR 2 — Sidebar shell

Goal: implement the single-window NavigationSplitView. Behind the flag, the user can launch with `CANOPY_SIDEBAR=1` and get the new shell. The legacy WindowGroup remains the default.

### Tasks

1. **`Sources/Canopy/Sidebar.swift`** — new file.
   - `List(selection: $store.selection)` with one `ForEach(store.visibleRows)`.
   - Top "+ New session" affordance binding to `select(.launcher)`.
   - Per-row view: leading icon (filled vs outline `desktopcomputer`, or `cloud`), VStack with title + project caption, trailing × button (visible on hover and on active row).
   - Active row uses accent tint.
   - Row click handler: `.open` → `select(.session(s.id))`, `.closedLocal` → `Task { await store.openLocal(entry) }`, `.closedCloud` → `Task { await store.openCloud(session) }`.
   - × handler: `Task { await store.closeSession(s.id) }`.
2. **`Sources/Canopy/Detail.swift`** — new file.
   - `ZStack { LauncherView; ForEach(openSessions) { SessionContainer } }` with `opacity` toggling per Probe #1.
3. **`Sources/Canopy/SessionContainer.swift`** — new file.
   - Wraps an `OpenSession` and renders WebView + StatusBarView + ConnectionOverlayView. Mostly copy-paste from existing TabContentView, retargeted at `session: OpenSession`.
4. **`Sources/Canopy/CanopyApp.swift`** — modify.
   - When `Settings.useSidebar` (or env `CANOPY_SIDEBAR=1`) is true, build a `Window("Canopy", id: "main") { NavigationSplitView { Sidebar } detail: { Detail } }`.
   - Else, the existing `WindowGroup` codepath stays as-is.
   - Cmd+N when flag is on → `store.select(.launcher)`. When off, existing behaviour.
5. **`SessionStore.openNew(...)` real implementation.**
   - Builds an `OpenSession`, spawns its `ShimProcess`, mounts the WebView, appends to `openSessions`, sets selection.
6. **`SessionStore.openLocal(entry)` real implementation.**
   - Same as `openNew` but with `--resume entry.id` and `origin = .local(entry.projectDirectory)`.
7. **`SessionStore.openCloud(session)` real implementation.**
   - Reuse the existing teleport flow (`RemoteSessionsBridge`). On success, build an `OpenSession` from the result and append.
8. **`SessionStore.closeSession(id)` real implementation.**
   - Calls `shim.stop()`, drops the strong refs, removes from `openSessions`.
   - If `selection == .session(id)`, picks the next-highest-`lastActiveAt` open session, falling back to `.launcher`.

### Verification

- Launch with `CANOPY_SIDEBAR=1`, verify single-window NavigationSplitView renders.
- Click "+ New session", pick a folder, hit Start. New row appears at the top, selected.
- Cmd+N goes back to Launcher, second session can be started. Verify both rows live (Activity Monitor shows two Node processes), switching is instant.
- Close the active session via ×; selection moves to the other open session.
- Close all open sessions; selection falls to Launcher.
- Close window; relaunch — both sessions are gone (PR 3 adds persistence).

## PR 3 — Filter, dedup, persistence

Goal: the sidebar is feature-complete enough to ship. Filtering works, cloud rows dedupe, state survives relaunch.

### Tasks

1. **Filter menu**.
   - Toolbar gear button on the sidebar column.
   - Popover with four pickers: Status (All / Open / Closed), Origin (All / Local / Cloud), Project (All + distinct list from rows), Last activity (Today / 7d / 30d / All).
   - "Clear filters" button.
   - Apply via `SidebarFilter.apply` on `visibleRows`.
   - Subtle dot on the gear icon when any filter is active.
2. **Dedup**.
   - In `Sources/Canopy/ClaudeSessionHistory.swift`, add `loadTeleportedFromMap()` that returns `[localSessionId: remoteSessionId]` by parsing `teleported-from` JSONL entries.
   - In `SessionStore.visibleRows` computation, drop any `.closedCloud` whose `id` is the value side of any local row's `teleported-from`.
3. **Persistence**.
   - `Sources/Canopy/SessionStorePersistence.swift` — Codable representation of OpenSession (origin, resumeId, title, project, lastActiveAt, model, effort, permissionMode, remoteHost — no shim/webview).
   - `SessionStore.init()` reads and rebuilds the open list **with status = .closed**. Each row appears in the sidebar as a closed row (icon outline). The user clicks to actually spawn.
   - Persist on every selection change and openSessions mutation. Debounce 500 ms.
   - UserDefaults key `canopy.sessionStore.v1`.
4. **Toast on missing JSONL during restore.**
   - If a persisted session's JSONL no longer exists locally, drop it and show a one-time non-modal toast.

### Verification

- Open three sessions, set filters (e.g. Status = Open), confirm only the open ones show.
- Clear filters; all rows return.
- Teleport a cloud session, watch the cloud row disappear and a local row replace it.
- Quit + relaunch: open list returns. Each row is closed (icon outline). Click one — spinner shows in icon slot, then row goes live.
- Delete a JSONL on disk between launches; relaunch; toast appears, row is gone from sidebar.

## PR 4 — Spinner, shortcuts, polish

Goal: the spawn UX feels right and keyboard-driven users are happy.

### Tasks

1. **Spinner in icon slot during spawn**.
   - When `OpenSession.status == .spawning`, the row's leading icon is a `ProgressView()` instead of `desktopcomputer`.
   - On the detail pane, a "Starting…" placeholder with the session title until the WebView's first paint.
2. **Cmd+W**.
   - When the active selection is `.session(id)`, close that session.
   - When the active selection is `.launcher`, default behaviour (close the window).
3. **Cmd+Shift+W**: close the window.
4. **Cmd+1…9**: jump to the Nth visible row. If the row is closed, this triggers the spawn (same as click).
5. **Cloud polling**.
   - When the sidebar is visible, refresh `cloud` every 30 s.
   - Pause when the app is in the background (`scenePhase == .background`).
6. **Filter persistence**.
   - `SidebarFilter` stored in UserDefaults.

### Verification

- Click a closed local row, watch the spinner in the icon slot, then green active state.
- Cmd+W closes the active session, selection moves to the next open one.
- Cmd+1..9 jumps and (if closed) spawns.
- Wait 30 s with sidebar visible, watch cloud rows refresh.
- Switch app to background, confirm polling pauses (log inspection).

## PR 5 — Flip the flag, delete legacy

Goal: ship 1.12.0 with the new shell as the only shell.

### Tasks

1. Default `Settings.useSidebar = true`. Remove the env-var override.
2. Delete the legacy `WindowGroup` + tabbing code path: `applicationShouldTerminate` per-tab logic, dock-icon-reopen restoration, multi-window menu items.
3. Strip `AppState` (or reduce to a thin façade if any view still reads it; goal is delete).
4. Update `CLAUDE.md`:
   - Replace per-window block diagram with single-window NavigationSplitView block diagram.
   - Add "Sidebar / SessionStore" section.
   - Note Cmd+W remap in "Key Learnings".
5. Mark `2026-04-29-single-window-sidebar.md` Status: Approved.
6. Release notes for 1.12.0 in the GitHub Release body call out:
   - Single window with sidebar.
   - Cmd+W now closes the session, not the window. Cmd+Shift+W closes the window.
   - Open in new window is removed (Phase D will reintroduce as opt-in).

### Verification

- Fresh install: launch behaves like the new shell from first frame, no flag knob anywhere.
- Existing user: their multi-window state from 1.11.x is forgotten; they see a single window with no open sessions, must reopen via the sidebar's closed entries (auto-restored from JSONL scan). One-time onboarding tip points at the sidebar.

## Out of scope for Phase A

- "Open in new window" command — Phase D.
- Right-click context menu on rows — Phase B.
- Sidebar search bar — Phase B.
- Drag-and-drop folder onto sidebar — Phase B.
- Group-by mode — Phase B.
- Pinned rows — Phase B+.
- Multi-display power user affordances — Phase D.

## Pre-flight artefacts (to keep or remove)

- `Sources/Canopy/_ProbeWebViewRetention.swift` — keep through PR 1 as a reference probe; remove in PR 5 cleanup. Already gated behind `#if DEBUG`.
- `tmp/probe-shim-resume.js` — keep in tmp/ (already gitignored). Reference for any future regression on `--resume` cycles.

## Risks and mitigations

- **NavigationSplitView edge cases on macOS 26**: tested live; pattern works. No fallback needed.
- **CC extension Cmd+N hook**: prototype check during PR 2; if the extension's webview swallows Cmd+N, intercept at the WKWebView keyDown level.
- **WebView memory ceiling**: today an open window costs ~150–200 MB. Same in the new model. Heavy users opening 10+ sessions hit the same problem they hit today; they self-regulate by closing.
- **Persistence corruption**: a malformed `canopy.sessionStore.v1` blob shouldn't crash launch. Decode with try?, fall back to empty on failure, keep the bad blob under a `.broken` suffix for support.
