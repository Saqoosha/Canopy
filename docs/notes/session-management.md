# Session management

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Cmd+Opt+S (sidebar toggle) and the toggle button are SwiftUI's `NavigationSplitView`, not ours.** Do not add `SidebarCommands`; `Detail.swift`'s `collapsedSidebarToggleClearance` only reserves room for the button.
- **Cmd+Ctrl+1..9 counts visible open session rows (launchers skipped); Cmd+1..9 counts panes.** The numbers can differ from a row's visual position.
- **Renames must go through `SessionStore.commitRename`**, which persists the user-owned mark AND calls `ShimProcess.noteUserRenamed`; the shim decides per prompt whether to regenerate and would otherwise overwrite the name.
- **Pane-header double-click is hit-tested in `installPaneFocusClickMonitor`, not SwiftUI.** It consumes the event only when a rename sheet opened.
- **Row/pane ordering: whichever the user aimed at holds still.** Drag moves panes to match rows (`moveOpenRows` → `placingLaunchers`, never `syncPaneOrderToRows`); plain click moves the row to the pane (`moveRowFollowingPaneAssignment`, only when ranks disagree); Cmd+click appends a pane then sorts it to the row (`openInNewPane` → `syncPaneOrderToRows`).
- **`syncPaneOrderToRows` is a plain sort by `openSessions` index; do not make it a targeted "move the dragged pane"** — that version mis-ordered multi-row drags and drags across filter-hidden panes.
- **Launcher panes are anchored to the session they sit behind (`launcherAnchors`), never pinned by index or by a count of paned rows** — both break when the filter hides a row. An anchor on a hidden row slides left.
- **Do not animate panes on reorder** (scroll position drifts); only sidebar rows animate.
- **`normalizeSavedFrameForSinglePane()` and the restore snapshot are mutually exclusive branches of one `if`.** The window frame is saved manually (`canopy.mainWindowFrame`); AppKit autosave keys change per `WindowGroup` instance.
- **Keep the quit alert's explicit `keyEquivalent` lines in `CanopyApp.swift`**: AppKit assigns Escape by button title, so a rename could put Escape on the destructive discard.
- **Restore is applied from the window content's `.task` (`applyPendingRestore`), and `makeRestored()` returns an empty store** — the first render must see an empty store or the sidebar toggle is dead/misplaced (see the note at its park site). It consumes the snapshot before applying (a crashing restore must not replay), skips under `CANOPY_RUN_LOGIC_PROBE=1`, and writes pane widths without `schedulePaneResize()`/`normalizePaneWeightsToVisualWidths()`.
- **Restore without the GUI:** `defaults write sh.saqoo.Canopy.debug canopy.sessionRestore.v1 -data "$(xxd -p -c 100000 snap.json)"`, then launch Debug. Enum payload `Codable` shape is `{"caseName":{"label":value}}`.
- **Resume: the extension passes no `--resume` at a fresh launch** (2.1.263); the SSH wrapper appends its own, and if both exist the last wins. Without a local transcript it silently starts fresh (`resumeDropped: true`, ignored by Canopy).
- **Resume and replay use different lookups (2.1.268):** `--resume` survives if a unique `<id>.jsonl` exists anywhere under `~/.claude/projects`; the webview only draws from the cwd's encoded folders plus `git worktree list`. A session can resume with context and render an empty chat; a removed worktree reopens only after its transcript is moved (`ClaudeSessionHistory.directoryToOpen`).
