# Single-Window Sidebar: Sessions in One App Window

**Date:** 2026-04-29
**Status:** Implemented (Phase A shipped in PR #47, legacy multi-window stripped in the follow-up cleanup PR — single-window sidebar is the only shell from 1.12.0 onward)

## Problem

Canopy today is a multi-window app: every session is its own `WindowGroup` window or NSWindow tab. New users have to manage window juggling; switching sessions costs cmd-` cmd-tab cmd-1 cycling. The Launcher only appears in fresh windows, so picking a different recent session means opening another window and dismissing the first.

The webview-side teleport feature (PR #47) added a "Claude Code on the Web" section to the Launcher, which proves the value of a unified browse-and-pick surface. But that surface is still trapped in a single Launcher view that disappears the moment you start a session.

We want **one window, persistent sidebar, fluid open/close like Arc/Chrome vertical tabs** — closer to Claude Desktop / Cursor / VS Code IDE shells. The sidebar shows every session the user has access to (running, on disk, in the cloud) as one flat sortable list.

## Goals

- One main window per app launch. Cmd+N creates a session, not a window.
- Sidebar persists across session switches. Selecting an item swaps the detail pane.
- Sessions toggle between **open** (live shim, hot, instant switch) and **closed** (history only, click to reopen). Open sessions show a × close button on hover, like Arc.
- Each row shows a kind icon (local computer / cloud / open dot), the session title, and the project name as a subtitle.
- Existing features keep working: SSH remote, status bar, settings, /resume, model + effort selection, branch checkout, Sparkle updates, deep links.
- The CC extension webview keeps its DOM state when its session is the active detail; closing a session releases the shim and webview entirely.
- Filter menu lets users narrow by status / origin / project / last activity.

## Non-Goals

- Memory caps on the number of open sessions. The user controls open/close explicitly via close buttons; no LRU eviction.
- Hibernating webview state to disk (we rely on `--resume` and JSONL persistence on next reopen).
- "Open in new window" affordance (deferred indefinitely; single window is the model).
- Group-by / advanced sorting beyond date desc within each block (Phase B+).

## Pre-flight Validation (done 2026-04-29)

Before writing the spec, two technical risks were probed:

**Probe #1 — WebView retention.** A `ZStack { ForEach { NSViewRepresentable<WKWebView> } }` with `opacity` toggling was instrumented (`Sources/Canopy/_ProbeWebViewRetention.swift`). 8 toggles over 16 s produced exactly two `makeNSView` calls (one per slot, at startup), zero `dismantleNSView` calls, and the WKWebView DOM state was preserved. Conclusion: **the opacity-toggle pattern is safe**, no external NSViewController cache needed.

**Probe #2 — shim restart cycle.** A standalone Node script (`tmp/probe-shim-resume.js`) spawned the vscode-shim twice with the same target session, ran init + launch_claude both times. Both cycles completed cleanly (code 0), saw matching session IDs, MCP servers connected each time, no errors. Conclusion: **closing and reopening a session via fresh shim spawn is reliable** for the closed→open transition (which is what Phase A actually needs — we don't suspend running shims).

## User-Visible Behaviour

```
┌─────────────────┬───────────────────────────────────────┐
│ + New session   │  (Detail pane, depends on selection)  │
│           [⚙ filter] │                                  │
│                 │                                       │
│ 💻● ぼくが…  ×  Canopy   ── if "Launcher" selected:     │
│ 💻● Fix PDF…  ×  whatever     existing LauncherView     │
│ 💻 Test msg…    Canopy                                  │
│ 💻 Pull latest…  Canopy   ── if a session selected:     │
│ ☁ Identify…  Whatever-Co/…   the WebView for that      │
│ 💻 Rename proj…  Canopy      session, status bar at the │
│ ☁ Review fix…  Canopy        bottom                     │
│ ─────────────── │                                       │
│ Saqoosha        │                                       │
└─────────────────┴───────────────────────────────────────┘
```

### Single flat list with row state

There is no Open / Closed section header. One `List`, one `ForEach`. Each row carries its own state visually:

| State | Icon | Tint | Trailing |
|-------|------|------|----------|
| Open + active selection | `desktopcomputer` filled | accent / blue | × close button |
| Open + inactive | `desktopcomputer` filled | secondary | × close button (on hover) |
| Spawning (closed → open) | spinner ⟳ in the icon slot | secondary | — |
| Closed local | `desktopcomputer` outline | tertiary | — |
| Closed cloud | `cloud` outline | tertiary | — |

The "×" appears on row hover (Arc/Chrome convention) and on the active row always. There is no extra dot — the filled-vs-outline `desktopcomputer` already encodes open/closed for local sessions, and `cloud` only ever appears closed (a teleport promotes the row to local).

### Sort order

1. **Open block** (live shims, any origin) — sorted by `lastActiveAt` desc.
2. **Closed block** (local + cloud mixed) — sorted by `lastModified` desc, kind irrelevant.

Open sessions always rise to the top. Within the closed block, a 30-min-old cloud session sits above a 2-hour-old local one. There is no visual divider between blocks; the icon difference is enough.

### Click behaviours

- **Click open row**: switch selection (instant; the WebView is already alive in the ZStack).
- **Click closed local row**: spawn a fresh shim with `--resume <jsonl_id>`. While starting, the row's icon becomes a spinner. On `ready`, the row flips to open + active.
- **Click closed cloud row**: run the existing teleport flow (target cwd resolution, branch dialog). On success, the cloud row disappears (teleport-deduplication, see below) and the new local row joins as open + active.
- **Click ×**: stop the shim, release the WebView, the row stays in the list as a closed local row (the JSONL persists). Selection moves to the *next open row* (Arc/browser convention); if none exists, selection falls back to Launcher.
- **Click "+ New session"**: select Launcher (top of detail). The user picks a directory there, hits Start, which adds a new open row at the top.

### De-duplication

`/v1/sessions` returns cloud-side records, including ones the user has already teleported. We dedupe at sidebar render time:

- For each closed local row, read its JSONL's `teleported-from.remoteSessionId` (already parsed by `c1.readTeleportMetadata` in the extension; we mirror this in Swift).
- If a cloud session's `id` matches any local row's `remoteSessionId`, drop the cloud row.

Result: each session appears exactly once. Teleport-then-close shows the local row, not the cloud row.

### Filter menu

A gear button in the sidebar top-right opens a popover (Claude Desktop convention):

```
Status        [All ▾]    ← All / Open only / Closed only
Origin        [All ▾]    ← All / Local / Cloud
Project       [All ▾]    ← list of distinct repos / dirs
Last activity [All ▾]    ← Today / 7d / 30d / All
─────────
Clear filters
```

Filters are AND-combined and persist to UserDefaults. The gear icon shows a subtle dot when any filter is active. Phase A ships with these four; `Group by` and advanced facets are Phase B.

### Keyboard

- **Cmd+N**: focus Launcher (new session entry point).
- **Cmd+W**: close the active session (= click the × on the active row). If the active selection is Launcher, default behaviour (close the window) applies.
- **Cmd+Shift+W**: close the window.
- **Cmd+1…9**: jump to the Nth row in the visible (post-filter) list, regardless of open/closed. Click semantics apply (closed rows trigger spawn).

### Spinner during spawn

When clicking a closed row, the row immediately swaps the icon for a SwiftUI `ProgressView()` and the title sits unchanged. The detail pane shows a "Starting…" placeholder for that session id (not a Launcher view) until the shim emits its first `ready` and the webview's first frame paints. Typical wait: 3–5 s for local resume, 5–15 s for cloud teleport (network + JSONL save + branch checkout).

## Architecture Changes

### 1. New session model

```swift
@Observable
final class SessionStore {
    /// Persisted via UserDefaults: open ids + selection.
    private(set) var openSessions: [OpenSession] = []
    var selection: SessionSelection = .launcher
    var recents: [SessionEntry] = []          // ClaudeSessionHistory.loadAllSessions()
    var cloud: [RemoteSession] = []           // RemoteSessionsAPI.listAll()
    var filter: SidebarFilter = .init()       // status / origin / project / last activity
    func openLocal(_ entry: SessionEntry) async
    func openCloud(_ session: RemoteSession) async
    func openNew(_ params: NewSessionParams)
    func closeSession(_ id: UUID)
    func select(_ sel: SessionSelection)
    func refreshRecents()
    func refreshCloud()
}

enum SessionSelection: Hashable {
    case launcher
    case session(UUID)                        // OpenSession.id
}

@Observable
final class OpenSession: Identifiable {
    let id = UUID()
    var origin: Origin                        // .local(URL), .remote(host, URL), .teleportedFrom(String)
    var resumeId: String                      // CC session uuid (always set)
    var title: String
    var project: String
    var status: Status                        // .spawning, .live, .crashed
    var lastActiveAt: Date
    var statusBar: StatusBarData              // moved off Coordinator
    var connection: ConnectionState           // moved off Coordinator
    var permissionMode: PermissionMode
    var model: String?
    var effortLevel: String?
    var shim: ShimProcess?                    // strong; nil only after closeSession
    var webView: WKWebView?                   // strong; nil only after closeSession
}
```

`SessionRef` (the union the sidebar renders) is computed from `openSessions + recents + cloud` after de-dup and filter:

```swift
enum SidebarRow: Identifiable, Hashable {
    case open(OpenSession)
    case closedLocal(SessionEntry)
    case closedCloud(RemoteSession)
}
```

### 2. SwiftUI shell

```swift
@main struct CanopyApp: App {
    @State private var store = SessionStore()
    var body: some Scene {
        Window("Canopy", id: "main") {
            NavigationSplitView {
                Sidebar(store: store)
            } detail: {
                Detail(store: store)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 1100, minHeight: 700)
        }
        .commands { /* Cmd+N, Cmd+1..9, Cmd+W, etc. */ }
        Settings { SettingsView() }
    }
}
```

`Sidebar` is `List(selection: $store.selection)` with one `ForEach` over `store.visibleRows`. The gear menu lives in the toolbar of the sidebar column. `Detail` is the ZStack-with-opacity pattern (validated by Probe #1).

### 3. WebView lifecycle

```swift
struct Detail: View {
    @Bindable var store: SessionStore
    var body: some View {
        ZStack {
            LauncherView(store: store)
                .opacity(store.selection == .launcher ? 1 : 0)
                .allowsHitTesting(store.selection == .launcher)
            ForEach(store.openSessions) { s in
                SessionContainer(session: s, store: store)
                    .opacity(store.selection == .session(s.id) ? 1 : 0)
                    .allowsHitTesting(store.selection == .session(s.id))
            }
        }
    }
}
```

Each `OpenSession` keeps its WebView mounted for the lifetime of the open state. No live cap; closing a session is the only way to drop its memory. The user's existing multi-window habits map onto multi-row-open habits with identical memory profile.

### 4. ShimProcess ownership

`OpenSession` is the long-lived strong owner of `ShimProcess` and `WKWebView`. `SessionContainer` only borrows them for rendering. `closeSession(id)` calls `shim.stop()`, drops the strong refs, and rebuilds `openSessions` without that entry. The static `ShimProcess.instances` weak set keeps `applicationShouldTerminate` working unchanged.

### 5. Status bar / connection state

Both currently live on the per-window `Coordinator`. Move them onto `OpenSession` so they survive selection changes and reflect the right session's state. `StatusBarView` and `ConnectionOverlayView` re-target when the active session changes; on a closed session they don't render.

### 6. Window restore

Replace per-window restoration with a single `SessionStorePersistence` blob:

- `selection`: `.launcher` or `.session(UUID)` — UUID resolved against `openSessions`.
- `openSessions`: array of `{ origin, resumeId, title, project, model, effort, permissionMode, remoteHost, lastActiveAt }`. No shim/webview state — those re-spawn on demand.

On launch, `SessionStore.restore()` rebuilds the open list **but starts every session as closed** (icon = `desktopcomputer` outline). The user clicks the row they want to reopen first; we don't auto-spawn N shims at launch. This avoids a 30-second wall-of-MCP-connections on cold start, and lets users with 10+ sessions feel responsive.

If the saved selection was `.session(UUID)` and that session existed, we restore the row and select it (still closed); on first interaction the shim spawns. If the JSONL is gone, we drop the row with a toast and fall back to `.launcher`.

### 7. Routing changes

| Old | New |
|---|---|
| `AppState.launchSession(...)` | `SessionStore.openNew(...)` |
| `AppState.backToLauncher()` | `store.select(.launcher)` |
| Window tab / NSWindow per session | `OpenSession` row in sidebar |
| `WindowGroup` + `addTabbingMode` | `Window` + `NavigationSplitView` |
| Coordinator's `webView`, `statusBar`, `connection` | `OpenSession`'s same-named properties |
| LauncherView's `appState` | `LauncherView`'s `store` |

`AppState` is removed; persistent settings move to `CanopySettings` (already a thing) and runtime session state moves to `SessionStore`.

## Phase Plan

### Phase A — Shell conversion (this milestone)
- `SessionStore`, `OpenSession`, `SidebarRow`, `SessionSelection`.
- `Sidebar.swift` with one ForEach, the row visual states, hover × button, click semantics, spinner-in-icon-slot for spawning.
- Gear → filter popover with Status / Origin / Project / Last activity.
- `Detail.swift` ZStack pattern.
- `SessionContainer.swift` rendering one OpenSession.
- Rewrite `CanopyApp` to single `Window` + NavigationSplitView; drop tabbing.
- Move status bar + connection state onto `OpenSession`.
- De-dup cloud rows against local `teleported-from`.
- `SessionStorePersistence`: persist open list + selection. Restore everything as closed.
- Cmd+N, Cmd+W, Cmd+1..9, Cmd+Shift+W.
- Cloud refresh: poll every 30 s while sidebar is visible, paused on background.

### Phase B — Sidebar polish
- Top-of-sidebar search bar across all rows.
- Right-click menu on rows (delete history, rename, reveal in Finder).
- Row drag from local file system → start a session there.
- Filter pill / chip showing active filters at a glance.
- Group by (project, last activity bucket) — turning the flat list into a grouped one when toggled in the gear menu.
- Pruning Launcher's own duplicate Recents/Sessions lists (sidebar handles them now).

### Phase C — (deferred / removed)
The original "hot multi-session with LRU" plan is dropped. No live cap, no eviction. Closing is explicit, like a browser tab.

### Phase D — Power-user polish
- Cmd+T = new session anywhere from the app (alias for Cmd+N).
- "Open in new window" command for users who genuinely need two displays — re-introduces a second `Window` scene with an independent split.
- Window restore preserves split widths.
- Sparkle dialogs and notifications anchor to the main window only.

## Trade-offs

- **Cmd+W remap**: closes session, not window. Documented; users can rebind via Settings.
- **Two surfaces for "Recents" in Phase A**: the sidebar lists them and Launcher still has its own list. Phase B unifies. Minor duplication.
- **Multi-display users lose the affordance** of putting two sessions on two displays. Phase D reintroduces it as opt-in.
- **No automatic session-startup parallelism**: opening 5 closed sessions in a row spawns shims serially in the user's clicking cadence. Each spawn takes ~5 s; clicking faster doesn't speed it up. This is fine — users rarely batch-open.
- **Filter persistence**: filters survive across launches (UserDefaults). Risk: user filters out everything, restarts, and doesn't see their session. Mitigation: gear-icon dot + the empty-state text suggests "Clear filters".

## Open Questions

1. **Cloud "running" sessions**: should they auto-attach (live tail) instead of teleport? Defer to Phase D.
2. **Session title generation**: still requested by the running shim; flows into `OpenSession.title`. Confirmed.
3. **Settings window**: stays separate (`Settings` scene). Confirmed.
4. **Per-row context menu** (right-click): Phase B.
5. **"Pinned" rows**: out of scope for now.

## Risks

- **Persistence churn**: every selection change writes to UserDefaults. Cheap, but if a user clicks rapidly we generate a lot of writes. Debounce on a 500 ms timer.
- **CC extension's Cmd+N hook**: extension webview may register Cmd+N via `vscode.commands`. Verify it doesn't conflict with the sidebar binding; either swallow at WebView keyDown or rebind.
- **NavigationSplitView on macOS 14+**: requires macOS 14 minimum. Canopy already targets 15.0+, no regression.
- **Tab bar removal**: existing users relying on Cmd+Shift+T or window tabs will notice. Release notes must call this out, plus a one-time onboarding tip.

## What's not in this spec

- Sidebar visual design beyond the rough wireframe (icons sizes, spacing, fonts). Implementation iterates.
- Cloud session running-state polling backoff for very stale sessions.
- Cross-row notification badges (Phase D idea).
