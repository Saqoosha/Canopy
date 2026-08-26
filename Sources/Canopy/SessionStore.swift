import AppKit
import Foundation
import Observation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionStore")

/// Identifies what the detail pane should render.
enum SessionSelection: Hashable {
    case launcher
    case session(UUID)
}

/// Top-level state for the single-window sidebar shell. Owns the open
/// sessions, knows what's selected, and remembers what's available to open
/// (recent local jsonls + cloud sessions).
///
/// Real method bodies for `openLocal`, `openCloud`, `openNew`, and
/// `closeSession` land in PR 2 (when the sidebar UI exists to drive them).
/// PR 1 only sets up the type and the read-only computed views the UI will
/// bind to.
@Observable
@MainActor
final class SessionStore {
    /// Weakly held global reference. AppKit-side code (the Cmd+W keyDown
    /// monitor in `AppDelegate`) reads `activeSession` from a closure that
    /// has no SwiftUI environment to receive an injected store. Set in
    /// `init`; auto-cleared on deinit via the weak ref.
    nonisolated(unsafe) static weak var shared: SessionStore?

    /// Live sessions: shim is up (or spawning), webview mounted, user can
    /// switch to any of these instantly.
    private(set) var openSessions: [OpenSession] = []

    /// What the detail pane is showing right now. Defaults to launcher.
    var selection: SessionSelection = .launcher

    /// Horizontal panes in the detail column. Left-to-right order. Every
    /// entry's sessionId must be present in openSessions; the store enforces
    /// this via closePane / auto-close on session drop.
    private(set) var panes: [PaneSlot] = []

    /// Index into `panes` for the currently focused pane. Always a valid
    /// index when panes is non-empty. Undefined (0) while panes is empty.
    private(set) var focusedPaneIndex: Int = 0

    /// Sessions that finished a turn while the user wasn't recently typing
    /// in their pane. Rendered as the green `SessionActivity.unread` dot in
    /// the sidebar and as the green LED on the MacroPad.
    ///
    /// A session with no pane counts as unfocused, so it is marked on finish
    /// and stays marked until the user types into its pane (or presses that
    /// pane's MacroPad key) — merely focusing it, by mouse or otherwise,
    /// does not clear it. See `MacroPadUnreadTracker.update`'s doc.
    ///
    /// The store only *holds* this; the edge detection that produces it lives
    /// in `MacroPadUnreadTracker`, driven by `MacroPadController`. It lives
    /// here rather than in the controller because the sidebar and the pad must
    /// never disagree about what a color means — a green key with no green dot
    /// would make the pad look broken. The controller runs whether or not a
    /// pad is plugged in, so the sidebar's dot does not depend on the hardware.
    ///
    /// `private(set)` for the same reason as `focusedPaneIndex`: the set has an
    /// invariant (⊆ `openSessions`) that only the tracker maintains, and a
    /// second writer would strand a green dot on a session that is gone.
    private(set) var unreadSessionIds: Set<OpenSession.ID> = []

    /// Sole entry point for `unreadSessionIds`. Called by `MacroPadController`
    /// after `MacroPadUnreadTracker` has recomputed the set from a complete
    /// session list.
    func setUnreadSessionIds(_ ids: Set<OpenSession.ID>) {
        unreadSessionIds = ids
    }

    static let paneAbsoluteCap: Int = 6
    /// Includes the 8pt drag target from PaneDivider's ZStack; the 1pt visible line is centered inside.
    static let paneDividerWidth: CGFloat = 8
    static let paneDefaultWidth: CGFloat = 800
    static let paneMinDragWidth: CGFloat = 100

    var focusedPane: PaneSlot? {
        guard panes.indices.contains(focusedPaneIndex) else { return nil }
        return panes[focusedPaneIndex]
    }

    func paneIndex(forSession id: OpenSession.ID) -> Int? {
        panes.firstIndex { if case .session(let sid) = $0.content { return sid == id } else { return false } }
    }

    /// Local JSONL history, refreshed via `refreshRecents()`.
    private(set) var recents: [SessionEntry] = []

    /// Cloud (claude.ai/code) sessions, refreshed via `refreshCloud()`.
    private(set) var cloud: [RemoteSession] = []

    /// Maps local jsonl session id → cloud session id it was teleported from.
    /// Used by `visibleRows` to drop already-teleported cloud rows.
    private(set) var teleportedFromMap: [String: String] = [:]

    /// Filter applied to `visibleRows`. Persists across launches.
    var filter: SidebarFilter = SessionStorePersistence.loadFilter() {
        didSet { SessionStorePersistence.saveFilter(filter) }
    }

    /// How closed sidebar rows are grouped. Persists across launches.
    var groupingMode: GroupingMode = SessionStorePersistence.loadGroupingMode() {
        didSet { SessionStorePersistence.saveGroupingMode(groupingMode) }
    }

    /// Resume id of the session that was active at last quit. The sidebar
    /// uses this to highlight that row on cold launch (the user can click to
    /// reopen). This is the ORDINARY launch path, where nothing auto-spawns
    /// and reopening is one click away. A Save-and-Quit launch is the other
    /// path and does spawn — see `makeRestored()`.
    var lastActiveResumeId: String? = SessionStorePersistence.loadLastActiveResumeId()

    /// Sidebar-hidden session ids. Closed local rows whose JSONL id is in
    /// this set are filtered out of `visibleRows`; cloud rows with id in
    /// the set are also hidden. Persists across launches.
    private(set) var hiddenIds: Set<String> = SessionStorePersistence.loadHiddenIds()

    /// True when the sidebar UI is currently visible. Cloud polling is paused
    /// otherwise. Set by the Sidebar view from `.task` / `.onDisappear`.
    var isSidebarVisible: Bool = false

    /// The session the rename sheet is currently editing, or nil when no sheet
    /// is up. Presenting from the store rather than from a row's own view is
    /// what lets two entry points — the sidebar's context menu and a
    /// double-click on a pane header — open the same sheet.
    /// `private(set)`: the two constructors below are the only vetted way in,
    /// and they are where the "cloud and launcher rows cannot be renamed" rule
    /// lives. A plain `var` let any code in the module present the sheet for a
    /// row those constructors reject.
    private(set) var renameTarget: RenameTarget?

    /// A session the user may rename, addressed by its `SessionTitleStore` key.
    ///
    /// `openSessionId` is separate from `sessionId` and both are needed: the
    /// store is keyed by the CLI's session id, while the live title the
    /// sidebar and pane header render lives on an `OpenSession` identified by
    /// a per-process UUID. A closed row has a `sessionId` and no
    /// `openSessionId`.
    struct RenameTarget: Identifiable, Equatable {
        /// `SessionTitleStore` key — the CLI session id, not `OpenSession.ID`.
        let sessionId: String
        /// The live session to update in place, when this row has one.
        let openSessionId: OpenSession.ID?
        let currentTitle: String

        var id: String { sessionId }
    }

    /// Open the rename sheet for a sidebar row, if that row is renameable.
    ///
    /// Cloud and launcher rows are not: a launcher stands for no session at
    /// all, and a cloud row's title belongs to the server rather than to
    /// `SessionTitleStore`. The id SHAPE is not the reason — nothing here
    /// establishes what a cloud id looks like, and `save` reports a rejected
    /// write anyway.
    func beginRename(row: SidebarRow) {
        switch row {
        case .open(let session):
            renameTarget = RenameTarget(
                sessionId: session.resumeId,
                openSessionId: session.id,
                currentTitle: session.title
            )
        case .closedLocal(let entry):
            // `SessionEntry.id` IS the CLI session id — it is built from the
            // JSONL's filename, which is that id.
            renameTarget = RenameTarget(
                sessionId: entry.id,
                openSessionId: nil,
                currentTitle: entry.title
            )
        case .closedCloud, .launcher:
            break
        }
    }

    /// Open the rename sheet for whatever session occupies a pane.
    /// A launcher pane has no session to name, so this is a no-op there.
    /// Returns whether a sheet was actually opened.
    ///
    /// The caller is an NSEvent monitor that consumes the click, and consuming
    /// one that opened nothing is worse than not handling it: on a launcher
    /// pane the double-click would neither rename nor let the window zoom, a
    /// completely dead gesture with nothing to explain it.
    @discardableResult
    func beginRenameForPane(at index: Int) -> Bool {
        guard panes.indices.contains(index),
              case .session(let openId) = panes[index].content,
              let session = openSessions.first(where: { $0.id == openId })
        else { return false }
        renameTarget = RenameTarget(
            sessionId: session.resumeId,
            openSessionId: session.id,
            currentTitle: session.title
        )
        return true
    }

    /// Apply a manual rename and close the sheet.
    ///
    /// The title is marked user-owned, which is what stops
    /// `SessionTitleGenerator` from overwriting it: generation now runs several
    /// times per session, so without the mark a name typed here would be
    /// replaced a few turns later and again on the next launch.
    ///
    /// An empty or unchanged title just dismisses — treating empty as "revert
    /// to automatic" would make the destructive reading of a stray Return the
    /// silent one.
    func commitRename(_ target: RenameTarget, to newTitle: String) {
        defer { renameTarget = nil }
        // Truncated to the one title length the app uses anywhere. The sheet
        // imposes no limit, and every automatic writer already truncates, so
        // skipping it here would let a rename be the one title that renders
        // long — until the next launch shortened it behind the user's back.
        let trimmed = ShimProcess.truncatedTitle(
            newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty, trimmed != target.currentTitle else { return }

        let session = target.openSessionId.flatMap { openId in
            openSessions.first(where: { $0.id == openId })
        }
        // The live session's id, not the one captured when the sheet opened.
        // `OpenSession.resumeId` is a `var`: a launcher-born session starts on
        // a placeholder UUID that `backfillResumeId` replaces the moment the
        // CLI reports its real one, and that can happen while the sheet is up.
        // Committing against the captured value then writes under a dead id —
        // and the failure is asymmetric, which is what makes it nasty: the
        // TITLE self-heals, because the `rename_tab` path re-saves it under the
        // real id, but with `userOwned: false`. So the name survives and the
        // mark does not, and automatic generation takes the session back a few
        // turns into the NEXT launch.
        let storeId = session?.resumeId ?? target.sessionId

        guard SessionTitleStore.save(title: trimmed, forSessionId: storeId, userOwned: true) else {
            // Three causes now, not one: a non-UUID id, a stored blob that did
            // not decode, or an encode failure. An earlier version of this
            // comment named only the first, and then asserted it in the log —
            // so a user renaming while the store was unreadable got a silent
            // no-op explained by a diagnosis that was provably wrong.
            // Nothing was persisted, so the UI is left alone rather than
            // showing a rename that would vanish at the next launch.
            logger.warning("Rename not persisted (bad id, or the stored titles could not be read or written)")
            return
        }

        if let session {
            session.title = trimmed
            // The live shim decides on every prompt whether to regenerate a
            // title, so it has to be told directly — persisting the mark alone
            // would only take effect on the next launch.
            session.shim?.noteUserRenamed(trimmed)
        } else {
            // Only closed rows need this: they read their label from
            // `SessionTitleStore` when `ClaudeSessionHistory` loads them, while
            // an open row was just updated in place above. Reloading anyway
            // re-parses up to 50 JSONLs for nothing.
            Task { await refreshRecents() }
        }
    }

    func cancelRename() {
        renameTarget = nil
    }

    /// Background polling task for cloud session refresh. Lives while the
    /// sidebar is visible.
    private var cloudPollTask: Task<Void, Never>?
    private let cloudPollInterval: Duration = .seconds(30)

    /// Recompute each pane's preferredWidth so it equals the pane's current
    /// on-screen visual width. Manual window resizes never touch the
    /// weights (WeightedPaneLayout scales visually from the bounds), so
    /// the stored weights drift from the on-screen pt widths. Call this
    /// before ANY consumer that treats preferredWidth as absolute pt:
    /// pane-list mutation (append / close / auto-close, whose sizer sums
    /// the weights into a window width) and divider-drag start (whose
    /// pt delta is applied directly to the weights).
    func normalizePaneWeightsToVisualWidths() {
        guard !panes.isEmpty else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && isCanopyWindow($0) })
                          ?? NSApp.windows.first(where: { isCanopyWindow($0) }) else { return }
        let sidebarW = PaneWindowSizer.measuredSidebarWidthTrustingCollapse(in: window)
        let detailW = max(0, window.frame.width - sidebarW)
        let visualWidths = PaneLayoutMetrics.paneWidths(
            detailWidth: detailW,
            weights: panes.map(\.preferredWidth),
            dividerWidth: Self.paneDividerWidth,
            minimumWidth: Self.paneMinDragWidth
        )
        for i in panes.indices where i < visualWidths.count {
            let w = visualWidths[i]
            if w > 0 {
                panes[i].preferredWidth = w
            }
        }
    }

    private func schedulePaneResize() {
        let paneWidths = panes.map { Int($0.preferredWidth) }
        logger.info("[Pane] schedulePaneResize called: panes=\(paneWidths) focused=\(self.focusedPaneIndex)")
        // Run the sizer synchronously in the same runloop tick as the pane
        // mutation. Any debounced Task.sleep would let SwiftUI reflow the
        // detail column *before* the window grew, and the first pane
        // would visibly shrink to half its width (and its embedded
        // WKWebView's scroll position would drift) before snapping back
        // once the sizer expanded the window.
        PaneWindowSizer.applyForCurrentPanes(store: self)
    }

    /// Surface the cap-reached hint on the focused session's status
    /// bar. Called by openNew / openCloud / Sidebar when a `.newPane`
    /// request hits the absolute cap. The text interpolates
    /// `paneAbsoluteCap` rather than spelling the number, because it is a
    /// user-facing string: a literal here silently starts lying the moment
    /// the cap moves, and nothing in the build or the probe would notice. Launcher-focused panes have no
    /// status bar, so the hint is logged and dropped.
    func showCapReachedHintOnFocusedPane() {
        guard let focused = focusedPane else { return }
        if case .session(let id) = focused.content,
           let session = openSessions.first(where: { $0.id == id }) {
            session.statusBar.showHint("Maximum \(Self.paneAbsoluteCap) panes")
            return
        }
        // Launcher-focused case: no session status bar to display on; hint is lost.
        // Log so it's diagnosable.
        logger.info("showCapReachedHint: panes at cap; focused pane is launcher; hint dropped")
    }

    /// Sorted, de-duplicated, filtered rows the sidebar should render.
    var visibleRows: [SidebarRow] {
        // Drop any closed local row whose JSONL id is also currently open —
        // the open row is the live representation; showing the recents copy
        // would be a duplicate.
        let openResumeIds = Set(openSessions.map(\.resumeId))
        let recentRows = recents
            .filter { !openResumeIds.contains($0.id) && !hiddenIds.contains($0.id) }
            .map(SidebarRow.closedLocal)
        let cloudRows = cloud
            .filter { $0.kind == .web && !hiddenIds.contains($0.id) }
            .map(SidebarRow.closedCloud)
        let allRows: [SidebarRow] =
            openSessions.map(SidebarRow.open) + recentRows + cloudRows
        let deduped = SidebarRow.deduped(allRows, teleportedFromMap: teleportedFromMap)
        let sorted = SidebarRow.sorted(deduped)
        // Launcher rows are added AFTER dedup / sort / filter, never before.
        // They stand for a live pane, and a pane the filter can hide would put
        // the row-order-is-the-pane-strip correspondence back where it started.
        return Self.interleavingLaunchers(into: filter.apply(to: sorted), panes: panes)
    }

    /// True when the active selection points at an open session.
    var activeSession: OpenSession? {
        if case .session(let id) = selection {
            return openSessions.first { $0.id == id }
        }
        return nil
    }

    /// All distinct project labels across the un-filtered row set — used to
    /// populate the Project picker in the filter popover.
    var allProjects: [String] {
        let unfiltered: [SidebarRow] =
            openSessions.map(SidebarRow.open)
            + recents.map(SidebarRow.closedLocal)
            + cloud.filter { $0.kind == .web }.map(SidebarRow.closedCloud)
        return SidebarFilter.projects(in: unfiltered)
    }

    init() {
        Self.shared = self
    }

    // No deinit cleanup: SessionStore lives for the app's lifetime
    // (single instance owned by CanopyApp). Process exit cancels in-flight
    // tasks. `Sidebar.onDisappear` calls `stopCloudPolling()` for the
    // visible-vs-hidden case.

    // MARK: - Selection

    func select(_ sel: SessionSelection) {
        selection = sel
        if case .session(let id) = sel,
           let open = openSessions.first(where: { $0.id == id }) {
            // Don't bump lastActiveAt on selection: that would re-sort the
            // open block on every click, like browser tabs would never do.
            // The open block's order is fixed at insertion time (newest at
            // the bottom via `openSessions.append(_:)` in openNew /
            // openCloud — browser-tab convention).
            if let idx = paneIndex(forSession: id) {
                focusedPaneIndex = idx
            } else {
                openInFocusedPane(id)   // seeds first pane on cold launch
            }
            lastActiveResumeId = open.resumeId
            SessionStorePersistence.saveLastActiveResumeId(open.resumeId)
        }
    }

    /// Public setter for `focusedPaneIndex` (which is `private(set)`). Used by
    /// Detail's per-pane tap gesture to move focus without exposing a raw write.
    func setFocusedPaneIndex(_ idx: Int) {
        guard panes.indices.contains(idx) else { return }
        focusedPaneIndex = idx
        syncSelectionToFocusedPane()
        makeFocusedPaneKeyResponder()
    }

    /// Hand keyboard first-responder status to the focused pane's WKWebView so
    /// keystrokes land in the chat input immediately. Mouse clicks give the
    /// webview firstResponder naturally via AppKit; keyboard-driven focus
    /// changes don't, so we do it manually.
    ///
    /// Callers where this actually matters (target WKWebView is already
    /// mounted): `setFocusedPaneIndex` (Cmd+1..9, tap-to-focus),
    /// `moveFocus` (Cmd+Opt+←/→), `closePane`'s survivor, and
    /// `openInFocusedPane`'s "session already in another pane" branch.
    ///
    /// Callers where the WKWebView isn't attached yet at call time
    /// (`webView.window == nil` so the guard returns): `openInFocusedPane`'s
    /// content-swap branch and the `cycleFocusedPaneSession → openInFocusedPane`
    /// chain. `WebViewContainer.makeNSView`'s own
    /// `DispatchQueue.main.async { window.makeFirstResponder(target) }`
    /// handles those once the mount completes. Keeping the redundant call
    /// costs nothing and future-proofs against mount-timing rearrangement.
    /// Launcher panes are also skipped harmlessly.
    private func makeFocusedPaneKeyResponder() {
        guard let pane = focusedPane,
              case .session(let id) = pane.content,
              let webView = openSessions.first(where: { $0.id == id })?.webView,
              let window = webView.window
        else { return }
        window.makeFirstResponder(webView)
    }

    /// Update selection + lastActiveResumeId from the currently focused pane's content.
    /// Called from setFocusedPaneIndex, moveFocus, openInFocusedPane,
    /// openLauncherInFocusedPane, and closePane so tap-to-focus, Cmd+Opt+arrow,
    /// Cmd+1..9, Cmd+Ctrl+1..9, Cmd+Shift+[/], and pane close all keep the
    /// sidebar highlight, activeSession, and persistence in sync.
    private func syncSelectionToFocusedPane() {
        guard let pane = focusedPane else { return }
        switch pane.content {
        case .session(let id):
            selection = .session(id)
            if let open = openSessions.first(where: { $0.id == id }) {
                lastActiveResumeId = open.resumeId
                SessionStorePersistence.saveLastActiveResumeId(open.resumeId)
            }
        case .launcher:
            selection = .launcher
        }
    }

    // MARK: - Open / close

    /// Build a brand-new (or `--resume`d) session and open it. The shim and
    /// webview are spawned lazily by SessionContainer's first render via the
    /// `boundSession` write-back path in WebViewContainer.
    @discardableResult
    func openNew(
        directory: URL,
        resumeId: String? = nil,
        sessionTitle: String? = nil,
        model: String? = nil,
        effortLevel: String? = nil,
        permissionMode: PermissionMode = .acceptEdits,
        remoteHost: String? = nil,
        customApi: ModelProvider? = nil,
        target: PaneTarget = .focused
    ) -> OpenSession {
        let origin: OpenSession.Origin = remoteHost.map { .remote(host: $0, path: directory) }
            ?? .local(directory)
        let title = sessionTitle ?? "Untitled"
        let project = remoteHost.map { "\($0):\(directory.lastPathComponent)" }
            ?? GitWorktree.projectDisplayName(for: directory)
        // The CLI ignores a --resume id that has no JSONL on disk, so for a
        // brand-new session this UUID is only a placeholder; ShimProcess's
        // backfillResumeId swaps in the CLI's real session id once the
        // webview reports it via update_session_state (or rename_tab —
        // both carry sessionId through the same handler).
        let session = OpenSession(
            origin: origin,
            resumeId: resumeId ?? UUID().uuidString,
            title: title,
            project: project,
            status: .spawning,
            permissionMode: permissionMode,
            model: model,
            effortLevel: effortLevel,
            customApi: customApi
        )
        // Don't persist remote-host paths in recents (matches existing behaviour).
        if remoteHost == nil {
            RecentDirectories.add(directory)
        }
        // Append (don't insert at top): browser-tab convention — newer
        // sessions go to the bottom of the Open list, preserving the
        // muscle-memory positions of earlier-opened sessions.
        openSessions.append(session)
        switch target {
        case .focused: select(.session(session.id))
        case .newPane:
            if !openInNewPane(session.id) {
                // If cap reached, hint on focused pane BEFORE the fallback overwrites content.
                if panes.count >= Self.paneAbsoluteCap {
                    showCapReachedHintOnFocusedPane()
                }
                openInFocusedPane(session.id)
            }
        }
        logger.info("openNew dir=\(directory.path, privacy: .public) resume=\(resumeId ?? "new", privacy: .public) remote=\(remoteHost ?? "local", privacy: .public)")
        return session
    }

    /// Open a closed local row by spawning a shim with --resume against the
    /// existing JSONL. If `permissionMode` is nil, falls back to the global
    /// default in `CanopySettings.defaultPermissionMode`.
    @discardableResult
    func openLocal(_ entry: SessionEntry, permissionMode: PermissionMode? = nil, target: PaneTarget = .focused) -> OpenSession {
        // If this session is already open, honor target (focused vs new pane).
        if let existing = openSessions.first(where: { $0.resumeId == entry.id }) {
            switch target {
            case .focused:
                select(.session(existing.id))
            case .newPane:
                if !openInNewPane(existing.id) {
                    if panes.count >= Self.paneAbsoluteCap {
                        showCapReachedHintOnFocusedPane()
                    }
                    openInFocusedPane(existing.id)
                }
            }
            return existing
        }
        return openNew(
            directory: entry.projectDirectory,
            resumeId: entry.id,
            sessionTitle: entry.title,
            permissionMode: permissionMode ?? CanopySettings.shared.defaultPermissionMode,
            customApi: ModelProviderStore.selectedProvider(),
            target: target
        )
    }

    /// Open a closed cloud row by running the teleport flow. Spawns a
    /// short-lived `RemoteSessionsBridge`, asks it to fetch the cloud
    /// session, saves the JSONL locally, and adds an OpenSession that
    /// resumes from the new local id.
    ///
    /// Branch checkout: if the cloud session was on a non-trivial branch,
    /// we attempt a `git checkout` automatically (no prompt — the sidebar
    /// flow is supposed to feel as direct as clicking a local row). If
    /// checkout fails, we still resume the session and surface the error
    /// via `teleportError`. Phase A keeps this simpler than LauncherView's
    /// dialog-based flow; PR 4 polish can re-introduce a confirmation if
    /// users want it.
    func openCloud(_ session: RemoteSession,
                   permissionMode: PermissionMode? = nil,
                   target: PaneTarget = .focused) {
        let mode = permissionMode ?? CanopySettings.shared.defaultPermissionMode
        Task { await openCloudAsync(session, permissionMode: mode, target: target) }
    }

    /// Most recent teleport error message, if any. Sidebar surfaces it via
    /// a toast. Cleared on successful teleport or when the user dismisses.
    var teleportError: String?

    /// Stages a teleport runs through. Used to drive the sidebar row
    /// spinner and the detail-pane overlay so the user can tell which
    /// part of the multi-second flow is currently running.
    enum TeleportStage: Equatable {
        case startingShim
        case downloading
        case checkingOutBranch(branch: String)

        var label: String {
            switch self {
            case .startingShim: return "Connecting…"
            case .downloading: return "Downloading session…"
            case .checkingOutBranch(let b): return "Switching to \(b)…"
            }
        }
    }

    /// Snapshot of an in-flight teleport. Sidebar matches `cloudId` to
    /// pick the row that should show the spinner; the detail pane reads
    /// `stage`/`title`/`project` to render its overlay.
    struct TeleportProgress: Equatable {
        let cloudId: String
        var stage: TeleportStage
        let title: String
        let project: String
    }

    /// In-flight teleport, or nil. Also acts as the "a teleport is
    /// already running" guard — concurrent flows would race on
    /// `teleportError`'s single slot.
    private(set) var teleporting: TeleportProgress?

    /// Back-compat accessor for callers that only need the id.
    var teleportingCloudId: String? { teleporting?.cloudId }

    func dismissTeleportError() { teleportError = nil }

    private func openCloudAsync(_ session: RemoteSession,
                                permissionMode: PermissionMode,
                                target: PaneTarget = .focused) async {
        guard teleporting == nil else {
            logger.info("openCloudAsync: a teleport is already in progress, ignoring")
            return
        }
        let projectLabel = (session.repoOwner.map { "\($0)/\(session.repoName ?? "?")" })
            ?? session.repoName
            ?? ""
        teleporting = TeleportProgress(
            cloudId: session.id,
            stage: .startingShim,
            title: session.summary,
            project: projectLabel
        )
        defer { teleporting = nil }
        teleportError = nil
        // 1. Resolve target cwd: prefer a unique matching recent clone; if
        //    zero matches or ambiguous, prompt the user with NSOpenPanel.
        guard let cwd = resolveTargetCwd(for: session) else {
            // User cancelled the folder picker.
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir),
              isDir.boolValue else {
            teleportError = "Working directory not found: \(cwd.path)"
            return
        }

        // Remember the picked directory so future teleports of sibling
        // sessions in the same repo auto-resolve without a second prompt.
        RecentDirectories.add(cwd)

        let bridge = RemoteSessionsBridge(cwd: cwd)
        do {
            try await bridge.start()
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            bridge.shutdown()
            return
        }
        defer { bridge.shutdown() }

        teleporting?.stage = .downloading
        let result: TeleportResult
        do {
            result = try await bridge.teleportSession(id: session.id)
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            return
        }

        // Auto-checkout the cloud session's branch when it's a real branch
        // name (skip "HEAD" / nil — those are detached / no-branch).
        if let branch = result.branch,
           !branch.isEmpty, branch != "HEAD" {
            teleporting?.stage = .checkingOutBranch(branch: branch)
            do {
                let ok = try await bridge.checkoutBranch(branch)
                if !ok {
                    try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: true)
                    teleportError = "Resumed locally but couldn't switch to branch '\(branch)'."
                }
            } catch {
                try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: true)
                teleportError = "Resumed locally but checkout failed: \(error.localizedDescription)"
            }
        }

        guard let localId = result.localSessionId else {
            teleportError = "Teleport completed but no local session id was returned."
            return
        }

        // Clear the teleport overlay before we mount SessionContainer.
        // SessionContainer shows its own SpawningOverlay (status == .spawning)
        // and we don't want two progress screens stacked on top of each other.
        teleporting = nil

        // Promote the cloud row to an OpenSession. The origin remembers the
        // cloud id so the sidebar can dedupe the cloud row out of view.
        let title = result.summary ?? session.summary
        let project = (session.repoOwner.map { "\($0)/\(session.repoName ?? "?")" })
            ?? cwd.lastPathComponent
        let opened = OpenSession(
            origin: .teleportedFrom(cloudSessionId: session.id, localPath: cwd),
            resumeId: localId,
            title: title,
            project: project,
            status: .spawning,
            permissionMode: permissionMode
        )
        // Append (don't insert at top): match openNew's browser-tab
        // convention so cloud reopens don't push existing Open rows
        // around.
        openSessions.append(opened)
        // Drop the cloud row immediately so the sidebar reflects the new
        // state without waiting for the next /v1/sessions poll.
        cloud.removeAll { $0.id == session.id }
        switch target {
        case .focused: openInFocusedPane(opened.id)
        case .newPane:
            if !openInNewPane(opened.id) {
                // If cap reached, hint on focused pane BEFORE the fallback overwrites content.
                if panes.count >= Self.paneAbsoluteCap {
                    showCapReachedHintOnFocusedPane()
                }
                openInFocusedPane(opened.id)
            }
        }
        // Refresh recents + teleportedFromMap so the new local JSONL is
        // picked up correctly (the JSONL was just written by the extension).
        await refreshRecents()
    }

    /// Map a cloud session to a local working directory: auto-resolve only
    /// when exactly one recent clone matches by name. Multiple matches are
    /// ambiguous (different clones of the same repo), and we'd otherwise
    /// run `checkoutBranch` on the wrong working copy. Zero or multiple
    /// matches drop into an NSOpenPanel so the user can point at the
    /// correct local clone. Returns nil only when the user cancels.
    private func resolveTargetCwd(for session: RemoteSession) -> URL? {
        if let name = session.repoName?.lowercased() {
            let matches = RecentDirectories.load().filter { $0.lastPathComponent.lowercased() == name }
            if matches.count == 1, let only = matches.first {
                return only
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let owner = session.repoOwner, let name = session.repoName {
            panel.message = "Pick the local clone of \(owner)/\(name) to teleport into"
        } else {
            panel.message = "Choose a local working directory for this remote session"
        }
        panel.prompt = "Use This Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Close an open session: stop the shim, drop the strong refs, move the
    /// selection to the next-most-recently-active open session (or launcher
    /// when none are left).
    /// Hide a closed row from the sidebar. Local jsonls aren't deleted —
    /// the data stays on disk; we just don't surface the row anymore. The
    /// user can clear hidden ids later via the (TBD) Settings panel.
    func hideClosedSession(rowId: String) {
        // rowId formats: "local:<uuid>", "cloud:<session_*>"
        let parts = rowId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let raw = String(parts[1])
        hiddenIds.insert(raw)
        SessionStorePersistence.saveHiddenIds(hiddenIds)
        logger.info("hideClosedSession id=\(raw, privacy: .public)")
    }

    func unhideAll() {
        hiddenIds.removeAll()
        SessionStorePersistence.saveHiddenIds(hiddenIds)
    }

    func closeSession(_ id: UUID) {
        guard let idx = openSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = openSessions[idx]
        logger.info("closeSession id=\(id.uuidString, privacy: .public) project=\(session.project, privacy: .public)")
        session.shim?.stop()
        session.shim = nil
        session.webView = nil
        openSessions.remove(at: idx)
        removePanesForClosedSession(id)

        // Derive selection from panes when possible; only fall back to the
        // browser-tab convention on openSessions when panes went empty.
        if !panes.isEmpty {
            switch panes[focusedPaneIndex].content {
            case .session(let sid): selection = .session(sid)
            case .launcher: selection = .launcher
            }
        } else if case .session(let sel) = selection, sel == id {
            if openSessions.isEmpty {
                selection = .launcher
            } else {
                // The closed session held the only pane. Put the next open
                // session INTO a pane, not just into `selection` — Detail
                // renders the Launcher whenever `panes` is empty, so a
                // selection-only update would show the Launcher while the
                // sidebar highlights a live session.
                let target = idx < openSessions.count ? idx : openSessions.count - 1
                openInFocusedPane(openSessions[target].id)
            }
        }

        // The shim was just writing to the session's JSONL, so the on-disk
        // metadata is newer than `recents` (which only refreshes explicitly —
        // sidebar appear and post-teleport). Reload so the now-closed
        // session shows up in the Recents block immediately.
        Task { await refreshRecents() }
    }

    // MARK: - Refresh

    /// Reload the local JSONL list. Cheap (parses headers only). The
    /// teleported-from map is loaded separately so the recents list isn't
    /// blocked behind it on slow disks.
    func refreshRecents() async {
        // 1. Sessions list — render the sidebar as soon as this returns.
        let all = await Task.detached { ClaudeSessionHistory.loadAllSessions() }.value
        await MainActor.run { self.recents = all }

        // 2. Teleport-from map — used only for cloud-row dedup. If it's
        //    slow, the user just sees the cloud row briefly until it
        //    finishes; nothing is blocked.
        let map = await Task.detached { ClaudeSessionHistory.loadTeleportedFromMap() }.value
        await MainActor.run { self.teleportedFromMap = map }
    }

    /// Hit the API for cloud sessions. Throws on auth/HTTP failure; callers
    /// should swallow and surface in the UI.
    func refreshCloud() async {
        do {
            let sessions = try await RemoteSessionsAPI.listAll()
            cloud = sessions
        } catch {
            logger.warning("refreshCloud failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cloud polling

    /// Start refreshing cloud sessions on a 30-s cadence. Pauses when the
    /// sidebar is hidden (window minimized, app in background, etc.).
    func startCloudPolling() {
        guard cloudPollTask == nil else { return }
        cloudPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isSidebarVisible {
                    await self.refreshCloud()
                }
                try? await Task.sleep(for: self.cloudPollInterval)
            }
        }
    }

    func stopCloudPolling() {
        cloudPollTask?.cancel()
        cloudPollTask = nil
    }

    // MARK: - Open-session reorder

    /// Pure core of drag-to-reorder. `visible` is the subset of `master` the
    /// sidebar is actually showing (filter-applied), in master order;
    /// `newVisible` is that list after the drag. The new visible order is
    /// written back into the visible slots of `master`, so hidden ids never
    /// change position.
    ///
    /// It takes the reordered list rather than `.onMove`'s offsets because a
    /// drag over the Open section no longer yields offsets that mean anything
    /// to `master` on their own — launcher rows are interleaved into those
    /// coordinates, so the caller strips them and hands the resulting session
    /// order straight in.
    ///
    /// Returns `master` unchanged when the visible order didn't actually move,
    /// or when `newVisible` isn't a permutation of `visible` (a caller bug —
    /// writing back a different SET would silently drop or duplicate rows).
    /// Checked as count plus set membership, which is exact only because
    /// `visible` never holds duplicates — the one production caller passes
    /// session ids, one per open session.
    static func applyVisibleOrder<T: Hashable>(
        master: [T],
        visible: [T],
        newVisible: [T]
    ) -> [T] {
        guard newVisible != visible,
              newVisible.count == visible.count,
              Set(newVisible) == Set(visible) else { return master }
        let visibleSet = Set(visible)
        var iterator = newVisible.makeIterator()
        return master.map { id in
            visibleSet.contains(id) ? (iterator.next() ?? id) : id
        }
    }

    /// Handle a drag-reorder from the sidebar's Open section. Offsets are in
    /// visible-row coordinates, and those rows are sessions AND launchers
    /// mixed — on top of which the filter may be hiding some session rows.
    ///
    /// One drag, two writes, because the two halves have different masters. A
    /// session row's order lives in `openSessions`, where filter-hidden rows
    /// keep their slots (`applyVisibleOrder`); a launcher row has no master
    /// but the pane strip itself. So the sessions are written back first and
    /// the pane order is then rebuilt, anchoring each launcher to the paned row
    /// it follows. Moving the launcher pane by index instead desynchronises the
    /// two the moment one drag moves a launcher and a session at once
    /// (multi-row drag), and — the case that forced this design — whenever a
    /// session is dragged PAST a launcher, since the launcher's index means
    /// nothing once its neighbours have permuted.
    ///
    /// **A launcher follows the drop when the row list can describe it, and
    /// keeps the strip's anchor when it cannot** — `draggedLauncherAnchors` is
    /// where that line falls. The row list is filter-applied, so a launcher
    /// sitting behind a hidden paned row has no truthful anchor in it, and
    /// re-reading every launcher from the rows re-homed those to the nearest
    /// VISIBLE row, sliding live panes across the strip on a drag that never
    /// touched them. Four independent reviewers found that, two by executing
    /// it; the degenerate case is a `.closedOnly` filter, where no paned row is
    /// visible at all and every launcher would collapse to the head.
    ///
    /// Selection is untouched — only positions change, matching browser-tab
    /// behaviour. Cmd+Ctrl+1..9 and Cmd+Shift+[/] both consume the visible
    /// open rows directly, so their targets follow the new order automatically.
    func moveOpenRows(fromOffsets: IndexSet, toOffset: Int) {
        let visible = visibleRows.filter(\.isOpen)
        // UI-supplied offsets: reject out-of-range input instead of letting
        // Array.move trap. (IndexSet can't hold negatives, so max() covers
        // the from side.)
        guard (fromOffsets.max() ?? -1) < visible.count,
              toOffset >= 0, toOffset <= visible.count else { return }
        var moved = visible
        moved.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard moved.map(\.id) != visible.map(\.id) else { return }

        let masterIds = openSessions.map(\.id)
        let newOrder = Self.applyVisibleOrder(
            master: masterIds,
            visible: visible.compactMap(Self.sessionId),
            newVisible: moved.compactMap(Self.sessionId)
        )
        if newOrder != masterIds {
            let byId = Dictionary(uniqueKeysWithValues: openSessions.map { ($0.id, $0) })
            openSessions = newOrder.compactMap { byId[$0] }
        }
        applyPaneOrder(Self.placingLaunchers(
            panes,
            rank: rowRank(),
            anchors: Self.draggedLauncherAnchors(
                movedRows: moved,
                pickedUp: fromOffsets.compactMap { idx -> PaneSlot.ID? in
                    guard visible.indices.contains(idx),
                          case .launcher(let slot) = visible[idx] else { return nil }
                    return slot
                },
                panes: panes
            )
        ))
        logger.info("moveOpenRows from=\(fromOffsets.map(String.init).joined(separator: ","), privacy: .public) to=\(toOffset)")
    }

    /// The session behind a row, or nil for a launcher / closed row.
    private static func sessionId(_ row: SidebarRow) -> OpenSession.ID? {
        if case .open(let s) = row { return s.id }
        return nil
    }

    /// The pane rendering `slot`, or nil if that pane is gone. The sidebar's
    /// launcher rows resolve their pane through this — three inline copies of
    /// `panes.firstIndex(where:)` lived in the view layer, which the probe
    /// cannot reach at all, and one of them decides which pane a close X tears
    /// down.
    func paneIndex(forSlot slot: PaneSlot.ID) -> Int? {
        panes.firstIndex { $0.id == slot }
    }

    /// True when the sidebar's rows hold nothing but launcher rows — every
    /// session row filtered away, or none open at all. The Open section is
    /// still drawn in that state, so the empty state has to ask this rather
    /// than `rows.isEmpty`, which a launcher pane makes unreachable.
    ///
    /// Takes the rows rather than reading `visibleRows`: the caller has them
    /// already, and a pure function is one the probe can reach — the view it
    /// serves is not.
    static func holdsOnlyLauncherRows(_ rows: [SidebarRow]) -> Bool {
        !rows.contains { row in
            if case .launcher = row { return false }
            return true
        }
    }

    /// Each open session's index in `openSessions` — the master order, which
    /// is filter-blind and so is NOT the sidebar's open block once a row is
    /// hidden or a launcher is interleaved.
    private func rowRank() -> [OpenSession.ID: Int] {
        var rank: [OpenSession.ID: Int] = [:]
        for (i, session) in openSessions.enumerated() { rank[session.id] = i }
        return rank
    }

    /// Re-order the panes so their left-to-right order matches the order their
    /// rows hold in the sidebar: session panes follow `openSessions`, and each
    /// launcher pane keeps the session pane it currently sits behind.
    ///
    /// Launcher panes used to hold their slot INDEX here, which was right only
    /// while they had no row. A launcher's ROW POSITION is derived from the
    /// strip (session rows run the other way — `openSessions` is their master),
    /// so for a launcher the two can never visibly disagree — what an index costs is the drop: rows
    /// [A][L][B], drag A to the bottom, and the drop reads [L][B][A], while
    /// pinning L at index 1 renders [B][L][A]. Self-consistent, and not what
    /// the user just dropped. Anchoring is what lets the strip follow it.
    ///
    /// The session half is a plain sort, not a move of just the dragged pane,
    /// and that is safe *because* `moveRowFollowingPaneAssignment` keeps the
    /// two orders in agreement everywhere else — a drag is the only thing that
    /// can put them out of step, so there is never stale disagreement for a
    /// sort to snap back. An earlier revision moved only the dragged panes and
    /// pinned filter-hidden ones by slot; three separate ordering bugs came out
    /// of that (a multi-row drag, and a drag crossing a hidden pane, both with
    /// and without an unpaned row in the mix). Sorting has none of those cases
    /// because it never reasons about indices. Do not "optimise" it back into
    /// a targeted move without first re-establishing that the orders can drift.
    ///
    /// Filter-hidden rows need no special handling: `applyVisibleOrder` keeps
    /// them at their master positions, so reading the order straight off
    /// `openSessions` already accounts for them. (`_probeSeedOpenSessions` is
    /// the one writer that can manufacture a disagreeing state — that is what
    /// it exists for, and it is `#if DEBUG`.)
    ///
    /// Anchors are read from the CURRENT pane order, because nothing about the
    /// launchers moved on the routes that reach this. The one route that knows
    /// better — `moveOpenRows` — bypasses this function entirely and calls
    /// `placingLaunchers` with anchors of its own.
    private func syncPaneOrderToRows() {
        applyPaneOrder(Self.placingLaunchers(
            panes,
            rank: rowRank(),
            anchors: Self.launcherAnchors(inPaneOrder: panes)
        ))
    }

    /// Commit a rebuilt pane strip. Focus follows slot IDENTITY rather than
    /// slot position, which is also why it survives the focused pane being a
    /// launcher. A no-op when the order is unchanged, so callers can run it
    /// unconditionally.
    ///
    /// The guard compares slot IDS only, so a `newPanes` that differs from the
    /// current strip in `content` or `preferredWidth` alone is DISCARDED, not
    /// applied. That is a constraint on callers, not a cheap safety net: every
    /// one of them passes a permutation of the same `PaneSlot` values.
    private func applyPaneOrder(_ newPanes: [PaneSlot]) {
        guard newPanes.map(\.id) != panes.map(\.id) else { return }
        let focusedSlotId = panes.indices.contains(focusedPaneIndex)
            ? panes[focusedPaneIndex].id
            : nil
        panes = newPanes
        if let focusedSlotId,
           let newIndex = panes.firstIndex(where: { $0.id == focusedSlotId }) {
            focusedPaneIndex = newIndex
        }
    }

    // MARK: - Row/pane correspondence (pure)

    /// Where one launcher pane sits in the row order: immediately behind the
    /// row of `after`, or at the head of the open block when nil.
    struct LauncherAnchor: Equatable {
        let slot: PaneSlot.ID
        let after: OpenSession.ID?
    }

    /// Insert a row per launcher pane into the sidebar's already-sorted,
    /// already-filtered open rows, so the Open block reads as the pane strip:
    /// launchers in pane order, interleaved among the session rows. It is one
    /// row per pane only while the filter hides nothing — a hidden session's
    /// pane has no row, which is the filter working, not this function.
    ///
    /// A launcher's position is expressed as **the session pane it sits behind**
    /// — never as a count of preceding rows. The first version counted, and a
    /// count is only an anchor while every paned row is visible: with the
    /// filter hiding one, "behind the 2nd paned pane" and "after the 2nd
    /// visible paned row" name different places, and the drawn order inverted
    /// against the strip. Ids do not drift, so the same anchor vocabulary now
    /// runs in both directions and `launcherAnchors(inRowOrder:panes:)` is this
    /// function's inverse by construction rather than by coincidence.
    ///
    /// When a launcher's own anchor row is hidden, the launcher slides LEFT to
    /// the nearest visible paned row (head, if there is none) — left, never
    /// right, since sliding right would put it after a pane it sits before and
    /// invert the order against the strip. Left is not the unique placement
    /// (an unpaned row constrains nothing, so a spot just past one would read
    /// the same); it is the only one the anchor vocabulary can name.
    static func interleavingLaunchers(
        into rows: [SidebarRow],
        panes: [PaneSlot]
    ) -> [SidebarRow] {
        guard panes.contains(where: { if case .launcher = $0.content { return true } else { return false } })
        else { return rows }

        // `sorted(_:)` puts the open block first, and launcher rows belong in
        // it — never among the closed rows under their date/project headings.
        let openRows = Array(rows.prefix { $0.isOpen })
        let closedRows = Array(rows.dropFirst(openRows.count))
        let visibleSessions = Set(openRows.compactMap(sessionId))

        // Walk the strip once, remembering the last session pane whose row is
        // actually on screen. That is each launcher's effective anchor.
        var head: [PaneSlot.ID] = []
        var behind: [OpenSession.ID: [PaneSlot.ID]] = [:]
        var lastVisible: OpenSession.ID?
        for slot in panes {
            switch slot.content {
            case .session(let sid):
                if visibleSessions.contains(sid) { lastVisible = sid }
            case .launcher:
                if let anchor = lastVisible {
                    behind[anchor, default: []].append(slot.id)
                } else {
                    head.append(slot.id)
                }
            }
        }

        var out: [SidebarRow] = head.map(SidebarRow.launcher)
        out.reserveCapacity(rows.count + head.count + behind.values.reduce(0) { $0 + $1.count })
        var emitted = Set(head)
        for row in openRows {
            out.append(row)
            guard let sid = sessionId(row), let trailing = behind[sid] else { continue }
            out.append(contentsOf: trailing.map(SidebarRow.launcher))
            emitted.formUnion(trailing)
        }
        // A launcher whose anchor row somehow never appeared still ships, at the
        // end of the open block. Unreachable while every anchor is drawn from
        // `visibleSessions` above; kept because the alternative is a live pane
        // with no row, which is the bug this whole file exists to prevent.
        for slot in panes where !emitted.contains(slot.id) {
            if case .launcher = slot.content { out.append(.launcher(slot.id)) }
        }
        return out + closedRows
    }

    /// The anchors to rebuild the strip with after a drag: the pane strip's own
    /// anchors, overridden by the row order for every launcher the rows can
    /// speak for.
    ///
    /// The dividing line is **whether the row list can describe that launcher
    /// faithfully**, not whether the user grabbed it. A drag of a SESSION
    /// across a launcher moves the launcher too — rows `[A][L][B]`, drag A to
    /// the bottom, and the drop says `[L][B][A]`; keeping L behind A there
    /// renders `[B][A][L]` and breaks the contract that the panes follow the
    /// order you dropped. So a launcher follows the rows whenever its anchor is
    /// the head or a session whose row is visible.
    ///
    /// It does NOT when its anchor row is filtered out: the rows simply do not
    /// contain that position, so reading one back re-homes the launcher to the
    /// nearest visible row and slides a live pane across the strip on a drag
    /// that never touched it. A launcher the user did pick up is the exception
    /// to the exception — that drop is a statement about that launcher, and it
    /// outranks the strip.
    static func draggedLauncherAnchors(
        movedRows: [SidebarRow],
        pickedUp: [PaneSlot.ID],
        panes: [PaneSlot]
    ) -> [LauncherAnchor] {
        let base = launcherAnchors(inPaneOrder: panes)
        guard !base.isEmpty else { return base }
        // Deliberately NOT gated on `pickedUp` being non-empty: a drag that
        // grabs no launcher still moves the session rows a launcher is
        // anchored between, so every launcher is re-resolved on every drag.
        let dragged = Set(pickedUp)

        // With no paned session row on screen — a `.closedOnly` filter, or a
        // project filter excluding every paned session — the row list cannot
        // say where a launcher sits relative to the SESSION panes at all. Every
        // anchor would read as "leftmost" and the drag would drive the session
        // panes to the right end of the strip. All the rows can carry in that
        // state is the order of launchers that share one anchor, which the
        // re-ordering below does; two launchers behind DIFFERENT hidden panes
        // stay put, because swapping them means crossing a pane the rows never
        // showed.
        let paned = panedSessionIds(panes)
        let visibleSessions = Set(movedRows.compactMap(sessionId))
        let rowsCanAnchor = visibleSessions.contains(where: paned.contains)
        let fromRows = Dictionary(
            launcherAnchors(inRowOrder: movedRows, panes: panes).map { ($0.slot, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolved = base.map { anchor -> LauncherAnchor in
            // Head-anchored launchers are always expressible: "leftmost" is a
            // position the row list has.
            let describable = anchor.after.map(visibleSessions.contains) ?? true
            guard rowsCanAnchor, describable || dragged.contains(anchor.slot),
                  let fromRow = fromRows[anchor.slot] else { return anchor }
            return fromRow
        }

        // `placingLaunchers` keeps the array's order for launchers sharing an
        // anchor, so this is how two launchers behind one session swap when
        // their rows do. Stable sort. The `?? Int.max` is defensive only —
        // every launcher pane has a row and launcher rows are never filtered,
        // so `movedRows` ranks all of them.
        let rowRank = Dictionary(
            movedRows.compactMap { row -> PaneSlot.ID? in
                if case .launcher(let slot) = row { return slot }
                return nil
            }.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        resolved.sort { (rowRank[$0.slot] ?? Int.max) < (rowRank[$1.slot] ?? Int.max) }
        return resolved
    }

    /// Read each launcher's anchor off the pane strip: the session pane to its
    /// left, or nil when it is leftmost.
    static func launcherAnchors(inPaneOrder panes: [PaneSlot]) -> [LauncherAnchor] {
        var out: [LauncherAnchor] = []
        var previousSession: OpenSession.ID?
        for slot in panes {
            switch slot.content {
            case .session(let sid): previousSession = sid
            case .launcher: out.append(LauncherAnchor(slot: slot.id, after: previousSession))
            }
        }
        return out
    }

    /// Read each launcher's anchor off a row order: the nearest PANED open row
    /// above it, or nil when there is none. Inverse of
    /// `interleavingLaunchers(into:panes:)` — unpaned rows are skipped there
    /// and skipped here, which is what makes the pair round-trip.
    static func launcherAnchors(
        inRowOrder rows: [SidebarRow],
        panes: [PaneSlot]
    ) -> [LauncherAnchor] {
        let panedSessions = panedSessionIds(panes)
        var out: [LauncherAnchor] = []
        var previousSession: OpenSession.ID?
        for row in rows {
            switch row {
            case .open(let session):
                if panedSessions.contains(session.id) { previousSession = session.id }
            case .launcher(let slot):
                out.append(LauncherAnchor(slot: slot, after: previousSession))
            case .closedLocal, .closedCloud:
                break
            }
        }
        return out
    }

    /// Rebuild the pane strip: session panes sorted by their rows' `rank`,
    /// each launcher pane re-inserted behind its anchor.
    ///
    /// Returns the input unchanged if the result would not be a permutation of
    /// it. Every branch here is meant to preserve the panes exactly, so that
    /// guard only fires on a bug — but the failure it prevents is a pane (and
    /// its live WKWebView) silently vanishing from the strip.
    static func placingLaunchers(
        _ panes: [PaneSlot],
        rank: [OpenSession.ID: Int],
        anchors: [LauncherAnchor]
    ) -> [PaneSlot] {
        // Ties are real — panes pointing at a session no longer in
        // `openSessions` violate an invariant `removePanesForClosedSession`
        // maintains, and they all share `Int.max` while parked at the end — and
        // they keep their current relative order because Swift's sort IS
        // stable and documented as such (SE-0372, implemented in Swift 5.8).
        // An earlier revision tie-broke on the pane's index explicitly, on a
        // comment asserting the opposite; the guarantee makes that dead weight.
        let sessionPanes = panes
            .filter { if case .session = $0.content { return true } else { return false } }
            .sorted { sessionRank($0, rank) < sessionRank($1, rank) }

        let launcherPanes = Dictionary(
            panes.compactMap { slot -> (PaneSlot.ID, PaneSlot)? in
                if case .launcher = slot.content { return (slot.id, slot) }
                return nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        // No early return for the launcher-free case: it would skip the
        // permutation guard at the bottom, which the doc above claims covers
        // this function. With no launchers `head` and `behind` stay empty and
        // `out` is just `sessionPanes`, so the general path is already right.
        let panedSessions = panedSessionIds(panes)
        var head: [PaneSlot] = []
        var behind: [OpenSession.ID: [PaneSlot]] = [:]
        var placed: Set<PaneSlot.ID> = []
        for anchor in anchors {
            guard let slot = launcherPanes[anchor.slot], !placed.contains(anchor.slot) else { continue }
            placed.insert(anchor.slot)
            // An anchor naming a session with no pane can't be honoured; the
            // head is the safe fallback because it never drops the pane.
            if let after = anchor.after, panedSessions.contains(after) {
                behind[after, default: []].append(slot)
            } else {
                head.append(slot)
            }
        }

        var out = head
        for pane in sessionPanes {
            out.append(pane)
            if case .session(let sid) = pane.content, let trailing = behind[sid] {
                out.append(contentsOf: trailing)
            }
        }
        // A launcher no anchor mentioned (caller bug) still ships, at the end.
        out.append(contentsOf: panes.filter { !placed.contains($0.id) && launcherPanes[$0.id] != nil })

        guard Set(out.map(\.id)) == Set(panes.map(\.id)), out.count == panes.count else { return panes }
        return out
    }

    private static func sessionRank(_ slot: PaneSlot, _ rank: [OpenSession.ID: Int]) -> Int {
        guard case .session(let sid) = slot.content else { return Int.max }
        return rank[sid] ?? Int.max
    }

    private static func panedSessionIds(_ panes: [PaneSlot]) -> Set<OpenSession.ID> {
        Set(panes.compactMap { slot -> OpenSession.ID? in
            if case .session(let sid) = slot.content { return sid }
            return nil
        })
    }

    /// Move `sessionId`'s row so its rank among paned rows matches its pane's
    /// rank among session panes. The sidebar reads as a map of the pane strip,
    /// so when a session enters a pane by a route that doesn't already place it
    /// correctly — a plain click loading an unpaned session into the focused
    /// pane, or Cmd+Shift+[/] cycling — **the row is what moves, never the
    /// pane**. Reordering panes instead would yank the session out of the pane
    /// the user just put it in, which is the strictly worse surprise.
    ///
    /// The rank check is not an optimization, it is what keeps this quiet: it
    /// makes the call a no-op whenever the two ranks already agree. That covers
    /// a freshly-opened session, whose row `openNew` appended to the bottom
    /// just before its pane was appended — without the check the row would jump
    /// above any unpaned rows sitting below the last paned one on every such
    /// open. (`openInNewPane` is a different route and never reaches here; it
    /// calls `syncPaneOrderToRows` instead.)
    ///
    /// It is NOT a no-op for every new session, and the doc used to claim that
    /// wrongly: `openNew`'s default target is `.focused`, so opening into an
    /// existing pane (Cmd+O, the launcher's Start without Cmd, a plain click on
    /// a closed row) does move the fresh row up to that pane's rank whenever
    /// the focused pane isn't the last SESSION pane — this ranks among session
    /// panes, so a launcher sitting rightmost doesn't count. That is this
    /// function working.
    ///
    /// Sessions already in a pane are untouched — `openInFocusedPane`'s
    /// focus-only branch never calls this, so pure selection still moves
    /// nothing.
    ///
    /// Filter-blind, exactly like `syncPaneOrderToRows` — neither reads
    /// `visibleRows`. Mapping the visible order onto the master one is
    /// `moveOpenRows`' job (`applyVisibleOrder`), and both helpers edit the
    /// master order, which is what has to be right once the filter clears. So
    /// a hidden paned row still counts toward the ranks here and can be the
    /// anchor the insert lands next to.
    private func moveRowFollowingPaneAssignment(_ sessionId: OpenSession.ID) {
        guard let paneIdx = paneIndex(forSession: sessionId) else { return }
        let sessionSlots = panes.indices.filter {
            if case .session = panes[$0].content { return true }
            return false
        }
        guard let paneRank = sessionSlots.firstIndex(of: paneIdx) else { return }

        let panedIds: Set<OpenSession.ID> = Set(panes.compactMap { slot in
            if case .session(let id) = slot.content { return id }
            return nil
        })
        let rowRanking = openSessions.map(\.id).filter { panedIds.contains($0) }
        guard let rowRank = rowRanking.firstIndex(of: sessionId),
              rowRank != paneRank,
              let from = openSessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        var reordered = openSessions
        let moved = reordered.remove(at: from)
        let othersInRowOrder = reordered.map(\.id).filter { panedIds.contains($0) }
        // Anchor on the paned row this pane sits to the RIGHT of, and land
        // directly after it (or directly before the first paned row when this
        // is the leftmost pane). Anchoring on the row that should FOLLOW us
        // also satisfies the ranking, but lands us on the far side of any
        // unpaned rows in between — a longer, more visible jump for the same
        // result. Either way the anchor is a paned row, never an absolute
        // index, so unpaned rows keep their positions.
        let insertAt: Int
        if paneRank == 0 {
            insertAt = othersInRowOrder.first
                .flatMap { first in reordered.firstIndex { $0.id == first } } ?? 0
        } else if paneRank - 1 < othersInRowOrder.count,
                  let predecessor = reordered.firstIndex(
                      where: { $0.id == othersInRowOrder[paneRank - 1] }) {
            insertAt = predecessor + 1
        } else {
            insertAt = reordered.count
        }
        reordered.insert(moved, at: insertAt)
        openSessions = reordered
    }

    // MARK: - Panes

    enum PaneTarget: Equatable { case focused, newPane }

    /// Show `sessionId` in the focused pane, honoring one-session-one-pane:
    /// - `panes` empty (fresh launch) → seed the first pane with this session
    ///   at paneDefaultWidth.
    /// - Session already lives in another pane → focus jumps to *that* pane
    ///   instead of duplicating. The caller's focused pane is left untouched.
    ///   This is the branch Cmd+Ctrl+1..9's "Show Session N" label leans on
    ///   for its focus-jump fallback; sidebar clicks route through here too.
    /// - Otherwise → replace the focused pane's content with the session.
    /// `makeFocusedPaneKeyResponder()` runs on the last two branches;
    /// the empty-panes seed branch relies on `WebViewContainer.makeNSView`'s
    /// own async first-responder handoff since the WKWebView doesn't exist
    /// yet at mutation time.
    func openInFocusedPane(_ sessionId: OpenSession.ID) {
        guard openSessions.contains(where: { $0.id == sessionId }) else { return }
        if panes.isEmpty {
            // Do NOT call schedulePaneResize here — WeightedPaneLayout
            // gives a single pane the whole detail column regardless of
            // its weight, so it fills whatever width the user already
            // has. Running the sizer would force-shrink a manually-
            // widened window down to paneDefaultWidth on plain-click
            // session open.
            panes = [PaneSlot(content: .session(sessionId), preferredWidth: Self.paneDefaultWidth)]
            focusedPaneIndex = 0
            syncSelectionToFocusedPane()
            return
        }
        // If this session already lives in a pane, focus that one instead of
        // duplicating (one session, one pane invariant).
        if let idx = paneIndex(forSession: sessionId) {
            focusedPaneIndex = idx
            syncSelectionToFocusedPane()
            makeFocusedPaneKeyResponder()
            return
        }
        panes[focusedPaneIndex].content = .session(sessionId)
        moveRowFollowingPaneAssignment(sessionId)
        syncSelectionToFocusedPane()
        makeFocusedPaneKeyResponder()
    }

    /// Snapshot of cycle-eligible sessions for the focused pane. Sessions
    /// currently in another pane are excluded (one-session-one-pane
    /// invariant would otherwise turn cycle into a focus-jump — the
    /// "cycle inside this pane" mental model breaks). Callers use this
    /// for both the cycle action and the menu-enable predicate so both
    /// stay in perfect lockstep.
    private struct FocusedPaneCycleContext {
        let available: [UUID]
        let currentSid: UUID?
    }

    private func focusedPaneCycleContext() -> FocusedPaneCycleContext? {
        guard !panes.isEmpty else { return nil }
        let visibleOpenIds = visibleRows.compactMap { row -> UUID? in
            if case .open(let s) = row { return s.id } else { return nil }
        }
        let occupiedElsewhere: Set<UUID> = Set(panes.enumerated().compactMap { pair in
            let (idx, slot) = pair
            guard idx != focusedPaneIndex,
                  case .session(let sid) = slot.content else { return nil }
            return sid
        })
        let currentSid: UUID? = {
            if case .session(let id) = focusedPane?.content { return id }
            return nil
        }()
        let available = visibleOpenIds.filter { id in
            !occupiedElsewhere.contains(id) || id == currentSid
        }
        return FocusedPaneCycleContext(available: available, currentSid: currentSid)
    }

    /// True when Cmd+Shift+[/] would visibly change the focused pane's
    /// content. Menu items bind to this so the shortcut greys out (rather
    /// than silently no-op'ing) when the focused pane already shows the
    /// only cycle-eligible session, or nothing eligible exists.
    var canCycleFocusedPaneSession: Bool {
        guard let ctx = focusedPaneCycleContext() else { return false }
        return ctx.available.contains { $0 != ctx.currentSid }
    }

    /// Cycle the focused pane's session to the prev/next entry in the
    /// sidebar's visible open rows. See `focusedPaneCycleContext` for
    /// how "eligible" is defined. No-op when nothing eligible would
    /// produce a visible change (menu items also `.disabled` in that state).
    func cycleFocusedPaneSession(delta: Int) {
        guard let ctx = focusedPaneCycleContext(), !ctx.available.isEmpty else { return }
        let start = ctx.currentSid.flatMap { ctx.available.firstIndex(of: $0) } ?? -1
        let n = ctx.available.count
        let next: Int
        if start < 0 {
            next = delta > 0 ? 0 : n - 1
        } else {
            next = ((start + delta) % n + n) % n
        }
        openInFocusedPane(ctx.available[next])
    }

    /// Replace focused pane's content with the launcher. Used by Cmd+N in
    /// multi-pane mode; single-pane Cmd+N routes through select(.launcher).
    func openLauncherInFocusedPane() {
        if panes.isEmpty {
            selection = .launcher
            return
        }
        panes[focusedPaneIndex].content = .launcher
        syncSelectionToFocusedPane()
    }

    /// Append a new pane for `sessionId`. Returns false if bounced (already
    /// in a pane — caller should visually flash the existing pane — or cap
    /// reached — caller should show the cap-reached hint).
    @discardableResult
    func openInNewPane(_ sessionId: OpenSession.ID) -> Bool {
        guard openSessions.contains(where: { $0.id == sessionId }) else { return false }
        if let existing = paneIndex(forSession: sessionId) {
            focusedPaneIndex = existing
            selection = .session(sessionId)
            return false
        }
        guard panes.count < Self.paneAbsoluteCap else { return false }
        // Freeze the existing panes at their actual on-screen widths before
        // appending. Otherwise WeightedPaneLayout's ratio math redistributes
        // detail-column space equally by weight, visibly shrinking the
        // existing pane(s) before the sizer grows the window.
        normalizePaneWeightsToVisualWidths()
        let width = focusedPane?.preferredWidth ?? Self.paneDefaultWidth
        panes.append(PaneSlot(content: .session(sessionId), preferredWidth: width))
        // Sort the new pane to where its ROW already sits, rather than moving
        // the row to the right end where the append put it. This is the one
        // assignment route where the user aimed at the row (Cmd+click on a
        // sidebar row) instead of at a pane, so the row is what holds still —
        // Cmd+clicking the top row puts its pane on the far left.
        //
        // A no-op for a freshly-opened session, which `openNew` appended to the
        // bottom of the rows just before this: last row, last pane, already in
        // agreement.
        syncPaneOrderToRows()
        // Read the index back: the sort may have moved this pane off the end.
        focusedPaneIndex = paneIndex(forSession: sessionId) ?? panes.count - 1
        selection = .session(sessionId)
        if let session = openSessions.first(where: { $0.id == sessionId }) {
            lastActiveResumeId = session.resumeId
            SessionStorePersistence.saveLastActiveResumeId(session.resumeId)
        }
        schedulePaneResize()
        return true
    }

    /// Append a new launcher pane. Returns false only when the cap is reached.
    @discardableResult
    func openLauncherInNewPane() -> Bool {
        guard panes.count < Self.paneAbsoluteCap else { return false }
        normalizePaneWeightsToVisualWidths()
        let width = focusedPane?.preferredWidth ?? Self.paneDefaultWidth
        panes.append(PaneSlot(content: .launcher, preferredWidth: width))
        focusedPaneIndex = panes.count - 1
        selection = .launcher
        schedulePaneResize()
        return true
    }

    /// Close the pane at `index`. Focus shifts to the left neighbor (or 0
    /// if the closed pane was leftmost). The underlying OpenSession stays
    /// in openSessions — closing a pane does not close the session.
    func closePane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        // Freeze surviving panes at their actual on-screen widths before
        // removal — the sizer below sums preferredWidth as absolute pt,
        // and after a manual window resize the stored weights are stale
        // (window would jump to the pre-resize widths otherwise).
        normalizePaneWeightsToVisualWidths()
        let wasFocused = index == focusedPaneIndex
        panes.remove(at: index)
        if panes.isEmpty {
            focusedPaneIndex = 0
            selection = .launcher
            schedulePaneResize()
            return
        }
        if wasFocused {
            focusedPaneIndex = max(0, min(index - 1, panes.count - 1))
        } else if index < focusedPaneIndex {
            focusedPaneIndex -= 1
        }
        syncSelectionToFocusedPane()
        schedulePaneResize()
        // Hand keyboard first-responder to the surviving pane's webview so
        // the user can keep typing without a click. Both triggers reach here
        // with first responder still on the CLOSING pane's webview, about to
        // be torn down — Cmd+W's monitor consumes the keyDown and the close
        // X's consumes the mouse-down, so neither ever hands it to a button
        // or to the window on the way in. Without this handoff the surviving
        // webview stays visually highlighted but keystrokes beep. It is a
        // no-op whenever the surviving focused pane's webview already holds
        // first responder, and for every launcher-pane survivor.
        makeFocusedPaneKeyResponder()
    }

    /// Bypasses the divider-drag floor. Used only by PaneWindowSizer's
    /// equal-share fallback where the mathematics might land just under
    /// 100 pt on tiny screens.
    func forceSetPaneWidth(at index: Int, to width: CGFloat) {
        guard panes.indices.contains(index) else { return }
        panes[index].preferredWidth = max(1, width)
    }

    /// Move focus by delta. wrap=true (default) → Cmd+Opt+← from leftmost
    /// jumps to rightmost, and vice versa. No-op when panes has 0 or 1.
    func moveFocus(delta: Int, wrap: Bool = true) {
        guard panes.count > 1 else { return }
        let n = panes.count
        let raw = focusedPaneIndex + delta
        let next = wrap ? ((raw % n) + n) % n : max(0, min(n - 1, raw))
        focusedPaneIndex = next
        syncSelectionToFocusedPane()
        makeFocusedPaneKeyResponder()
    }

    /// Update two adjacent panes' preferred widths from a divider drag.
    /// Sum is preserved; values below the floor snap up and the overflow
    /// is reflected onto the other side.
    func setAdjacentPaneWidths(leftIndex: Int, leftWidth: CGFloat, rightWidth: CGFloat) {
        let rightIndex = leftIndex + 1
        guard panes.indices.contains(leftIndex), panes.indices.contains(rightIndex) else { return }
        let floor = Self.paneMinDragWidth
        let sum = leftWidth + rightWidth
        // Both sides need floor; if the sum can't afford both, reject the whole write.
        guard sum >= 2 * floor else {
            logger.warning("setAdjacentPaneWidths: sum \(sum) below 2*floor (\(2 * floor)); rejecting")
            return
        }
        let clampedLeft = min(max(floor, leftWidth), sum - floor)
        let clampedRight = sum - clampedLeft
        panes[leftIndex].preferredWidth = clampedLeft
        panes[rightIndex].preferredWidth = clampedRight
    }

    /// Called by closeSession(_:) after the session is removed from
    /// openSessions. Drops any pane pointing at the closed session.
    /// Does NOT mutate `selection` — `closeSession` derives it from the
    /// surviving focused pane (or falls back to openSessions order when
    /// panes went empty).
    private func removePanesForClosedSession(_ id: OpenSession.ID) {
        let matching = panes.enumerated().compactMap { (i, slot) -> Int? in
            if case .session(let sid) = slot.content, sid == id { return i } else { return nil }
        }
        guard !matching.isEmpty else { return }
        // Same rationale as closePane: sync weights to visual widths before
        // the sizer sums the survivors into the new window width.
        normalizePaneWeightsToVisualWidths()
        for idx in matching.reversed() {
            let wasFocused = idx == focusedPaneIndex
            panes.remove(at: idx)
            if panes.isEmpty { focusedPaneIndex = 0 }
            else if wasFocused { focusedPaneIndex = max(0, min(idx - 1, panes.count - 1)) }
            else if idx < focusedPaneIndex { focusedPaneIndex -= 1 }
        }
        schedulePaneResize()
    }

    // MARK: - Launch restore

    /// Snapshot the current pane strip for quit-time persistence. Only
    /// sessions a pane references are included — see `SessionRestoreSnapshot`.
    func captureRestoreSnapshot() -> SessionRestoreSnapshot {
        // preferredWidth is a weight until this runs; the snapshot stores
        // absolute pt measured against the live window.
        normalizePaneWeightsToVisualWidths()

        var sessions: [SessionRestoreSnapshot.Session] = []
        var panesOut: [SessionRestoreSnapshot.Pane] = []
        var seenResumeIds = Set<String>()
        // Silently skipping a missing session without this would shift focus
        // onto whatever pane slid left into the stored index.
        var droppedBeforeFocus = 0

        for (index, slot) in panes.enumerated() {
            switch slot.content {
            case .launcher:
                panesOut.append(.init(content: .launcher, width: slot.preferredWidth))
            case .session(let id):
                guard let open = openSessions.first(where: { $0.id == id }) else {
                    if index < focusedPaneIndex { droppedBeforeFocus += 1 }
                    continue
                }
                panesOut.append(.init(content: .session(resumeId: open.resumeId), width: slot.preferredWidth))
                if seenResumeIds.insert(open.resumeId).inserted {
                    let origin: SessionRestoreSnapshot.Session.Origin
                    switch open.origin {
                    case .local(let url):
                        origin = .local(path: url.path)
                    case .remote(let host, let path):
                        origin = .remote(host: host, path: path.path)
                    case .teleportedFrom(let cloudId, let path):
                        origin = .teleported(cloudSessionId: cloudId, path: path.path)
                    }
                    sessions.append(SessionRestoreSnapshot.Session(
                        resumeId: open.resumeId,
                        title: open.title,
                        project: open.project,
                        origin: origin,
                        permissionMode: open.permissionMode,
                        model: open.model,
                        effortLevel: open.effortLevel,
                        providerId: open.customApi?.id,
                        lastActiveAt: open.lastActiveAt
                    ))
                }
            }
        }

        return SessionRestoreSnapshot(
            sessions: sessions,
            panes: panesOut,
            focusedPaneIndex: focusedPaneIndex - droppedBeforeFocus
        )
    }

    /// Rebuild `openSessions` + `panes` from a quit-time snapshot. This is
    /// where sanitization happens — callers hand over the raw stored blob and
    /// every drop rule (missing transcript, duplicate pane, pane cap, focus
    /// clamp) is resolved here, so there is exactly one place a restore can
    /// decide something is unusable.
    func applyRestoreSnapshot(_ snapshot: SessionRestoreSnapshot) {
        let clean = snapshot.sanitized(
            paneCap: Self.paneAbsoluteCap,
            sessionIsResumable: SessionRestoreSnapshot.resumableOnDisk
        )
        guard !clean.isEmpty else {
            // The one path where the user clicked a button promising to
            // restore their layout and gets an empty Launcher. `makeRestored`
            // has already consumed the key, so without this line there is no
            // evidence anywhere that a snapshot ever existed — and the
            // reachable causes are environmental (a missing Documents TCC
            // grant makes `fileExists` reject every local cwd, a worktree
            // deleted between quit and launch, a version bump), not bugs the
            // user can see. `notice`, not `info`: `info` lives in an in-memory
            // ring buffer, which is the wrong lifetime for the only trace of
            // a silent failure.
            logger.notice("restore: snapshot held \(snapshot.panes.count) pane(s) / \(snapshot.sessions.count) session(s), none survived sanitize — launching to the Launcher")
            return
        }

        let providers = ModelProviderStore.load()
        var byResumeId: [String: OpenSession] = [:]
        var restored: [OpenSession] = []
        for s in clean.sessions {
            let origin: OpenSession.Origin
            switch s.origin {
            case .local(let path):
                origin = .local(URL(fileURLWithPath: path))
            case .remote(let host, let path):
                origin = .remote(host: host, path: URL(fileURLWithPath: path))
            case .teleported(let cloudId, let path):
                origin = .teleportedFrom(cloudSessionId: cloudId, localPath: URL(fileURLWithPath: path))
            }
            let provider = s.providerId.flatMap { id in providers.first { $0.id == id } }
            let open = OpenSession(
                origin: origin,
                resumeId: s.resumeId,
                title: s.title,
                project: s.project,
                status: .spawning,
                lastActiveAt: s.lastActiveAt,
                permissionMode: Self.clampedPermissionMode(s.permissionMode),
                model: s.model,
                effortLevel: s.effortLevel,
                customApi: provider
            )
            byResumeId[s.resumeId] = open
            restored.append(open)
        }
        openSessions = restored

        panes = clean.panes.compactMap { pane in
            let content: PaneContent
            switch pane.content {
            case .launcher:
                content = .launcher
            case .session(let resumeId):
                guard let open = byResumeId[resumeId] else { return nil }
                content = .session(open.id)
            }
            return PaneSlot(content: content, preferredWidth: pane.width)
        }

        focusedPaneIndex = min(max(0, clean.focusedPaneIndex), max(0, panes.count - 1))
        syncSelectionToFocusedPane()
        // Do not call schedulePaneResize / normalizePaneWeightsToVisualWidths:
        // the window frame is restored independently from canopy.mainWindowFrame
        // by AppDelegate.configureCanopyWindow, and it is the same frame these
        // widths were measured against — running the sizer would fight it.
        // `notice` so the success and failure lines share a lifetime — a
        // report of "my panes didn't come back" is diagnosable only if both
        // outcomes survive in the log.
        logger.notice("applyRestoreSnapshot: restored \(self.panes.count) pane(s) / \(self.openSessions.count) session(s) from \(snapshot.panes.count) stored")
    }

    /// Re-apply the bypass-permissions opt-in to a mode that came from disk.
    ///
    /// Every other route to a `PermissionMode` already clamps: `CanopySettings`
    /// does it in both `didSet` and `load()` for `defaultPermissionMode`, and
    /// `LauncherView.resolvedPermission` does it for a launcher choice. Restore
    /// is a third route, and the snapshot is plain JSON in UserDefaults — i.e.
    /// exactly the "stale settings paired bypass with a disabled opt-in (manual
    /// edit, downgrade)" case `CanopySettings`' own clamp comment names. Without
    /// this, quitting with a bypass session and then turning the toggle OFF
    /// brings that session back in bypass on the next launch, with the launcher
    /// Picker still hiding the mode.
    private static func clampedPermissionMode(_ mode: PermissionMode) -> PermissionMode {
        guard mode == .bypassPermissions,
              !CanopySettings.shared.allowDangerouslySkipPermissions else { return mode }
        logger.notice("restore: clamping .bypassPermissions → .acceptEdits (opt-in is off)")
        return .acceptEdits
    }

    /// Factory that consumes a quit-time snapshot (if any) and schedules it onto
    /// a fresh store. The store is returned EMPTY; a snapshot that was found is
    /// applied one main-queue drain later, deliberately — see the deferral note
    /// at the call below.
    ///
    /// The consume-before-apply order is load-bearing: a snapshot that crashes
    /// the restore would otherwise be replayed on every launch forever, and
    /// each replay tries to spawn N shims. This is a factory instead of work
    /// inside `init()` because `_SidebarLogicProbe` constructs bare
    /// `SessionStore()`s all over, and restoring inside `init` would contaminate
    /// every one of those with the developer's real saved layout.
    static func makeRestored() -> SessionStore {
        let store = SessionStore()
        // The probe decides whether to run in `applicationDidFinishLaunching`,
        // which is AFTER this `@State` initializer. Without this guard a local
        // `CANOPY_RUN_LOGIC_PROBE=1` run consumes the developer's real saved
        // layout — the key is one-shot by design — and spawns its sessions'
        // shims and CLIs, all before a single assertion has executed. The
        // factory alone does not insulate the probe; only this does.
        // `#if DEBUG` to match the thing it protects: `_SidebarLogicProbe` is
        // `#if DEBUG` at file scope, so a Release build has no probe to
        // insulate and must never let a stale `CANOPY_RUN_LOGIC_PROBE=1`
        // export in a terminal skip a real user's restore.
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else {
            return store
        }
        #endif
        guard let snapshot = SessionStorePersistence.loadRestoreSnapshot() else {
            return store
        }
        SessionStorePersistence.clearRestoreSnapshot()
        // Deferred by one main-queue drain, NOT inline — the delay is the whole
        // point and removing it silently breaks the sidebar-toggle button.
        //
        // Symptom, measured on macOS 26.6: after a restore launch the
        // `NavigationSplitView` sidebar-toggle button is hit and fires — its
        // accessibility label flips between "Show Sidebar" and "Hide Sidebar" —
        // but the split view never moves in response to it, for as long as that
        // window was watched. Cmd+Opt+S and the View menu item keep working,
        // which is what makes it read as
        // "the button is dead" rather than "the split view is stuck". WHY those
        // paths differ was NOT established; do not build on a mechanism here,
        // there isn't one.
        //
        // What the deferral is anchored to is an observation, not a contract:
        // enqueued from an `App`-level `@State` initializer, this block was
        // measured to land after the first render. Nothing enforces that and
        // nothing detects it regressing — the symptom is the dead button above.
        // `Task { @MainActor in }` was never measured here; the `.task` on the
        // window's content in `CanopyApp` was not tried either.
        //
        // Bisected against a working baseline rather than guessed. Healthy when
        // panes are opened after launch (0/1/2/4 panes, after a divider drag,
        // after Cmd+Opt+S) and broken by a restore launch carrying as few as ONE
        // pane — so pane count is not the variable. The three heals tried, all
        // of which failed, are a window resize, a pane close, and dropping back
        // to one pane.
        //
        // It is the LAUNCH that matters, not first-render-with-panes in general.
        // Measured: destroy the window with panes still non-empty (a launcher
        // pane, so `ShimProcess.hasActiveSession` is false and Cmd+Shift+W
        // closes rather than hides) and re-create it with Cmd+0, and that fresh
        // window's toggle collapses AND expands normally — twice, in both
        // directions — even though `panes` was already populated at its own
        // first render. So a later scene instance is fine and only the initial
        // one is poisoned; what actually distinguishes them is unidentified.
        //
        // Two other fixes were built and measured and BOTH failed, so don't
        // re-try them: passing an explicit `columnVisibility:` binding to the
        // NavigationSplitView (the toggle writes the binding and SwiftUI still
        // ignores it), and shrinking `WeightedPaneLayout.sizeThatFits`'s
        // nil-proposal fallback so the detail column stops reporting a wide
        // ideal width. Several minimal repro builds all toggle fine, including one
        // that rendered four panes at its OWN first render out of a custom
        // `Layout` with `.ignoresSafeArea(edges: .top)` children, WKWebViews,
        // `.toolbar(removing: .title)`, `.windowStyle(.hiddenTitleBar)` and
        // `.navigationSplitViewStyle(.balanced)`. Other builds carried a
        // Canopy-shaped sidebar or the window delegate proxy, but no single
        // build combined everything — so this narrows the suspects, it does not
        // eliminate them.
        //
        // To check whether this is still needed on a newer macOS: make the call
        // inline again, Save-and-Quit with at least one SESSION pane (the prompt
        // is gated on a live shim, and a strip of launcher panes stores no
        // snapshot), relaunch, click the toggle.
        //
        // The cost is not just a frame. `panes.isEmpty` renders `DetailLauncher`,
        // so a restore launch runs launcher startup work: `LauncherView.onAppear`
        // starts a detached `loadAllSessions()` scan and a marketplace query. A
        // snapshot holding a launcher pane paid that anyway.
        //
        // Safe because nothing else writes what the restore assigns in that
        // window — `openSessions`, `panes`, `focusedPaneIndex`, `selection`, and
        // `lastActiveResumeId` (which it also persists) — and
        // `applyRestoreSnapshot` assigns them wholesale rather than merging.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { store.applyRestoreSnapshot(snapshot) }
        }
        return store
    }

    #if DEBUG
    /// Probe-only seeding helper. `openSessions` is `private(set)` (setter
    /// file-private), so `_SidebarLogicProbe` cannot assign it directly.
    func _probeSeedOpenSessions(_ sessions: [OpenSession]) {
        openSessions = sessions
    }
    #endif
}
