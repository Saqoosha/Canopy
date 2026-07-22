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

    static let paneAbsoluteCap: Int = 5
    static let paneDividerWidth: CGFloat = 1
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
    /// reopen). Phase A doesn't auto-spawn the shim — restoration is one
    /// click away, with no MCP-connection wall-of-startup at launch.
    var lastActiveResumeId: String? = SessionStorePersistence.loadLastActiveResumeId()

    /// Sidebar-hidden session ids. Closed local rows whose JSONL id is in
    /// this set are filtered out of `visibleRows`; cloud rows with id in
    /// the set are also hidden. Persists across launches.
    private(set) var hiddenIds: Set<String> = SessionStorePersistence.loadHiddenIds()

    /// True when the sidebar UI is currently visible. Cloud polling is paused
    /// otherwise. Set by the Sidebar view from `.task` / `.onDisappear`.
    var isSidebarVisible: Bool = false

    /// Background polling task for cloud session refresh. Lives while the
    /// sidebar is visible.
    private var cloudPollTask: Task<Void, Never>?
    private let cloudPollInterval: Duration = .seconds(30)

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
        return filter.apply(to: sorted)
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
        customApi: ModelProvider? = nil
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
        select(.session(session.id))
        logger.info("openNew dir=\(directory.path, privacy: .public) resume=\(resumeId ?? "new", privacy: .public) remote=\(remoteHost ?? "local", privacy: .public)")
        return session
    }

    /// Open a closed local row by spawning a shim with --resume against the
    /// existing JSONL. If `permissionMode` is nil, falls back to the global
    /// default in `CanopySettings.defaultPermissionMode`.
    @discardableResult
    func openLocal(_ entry: SessionEntry, permissionMode: PermissionMode? = nil) -> OpenSession {
        // If this session is already open, just select it.
        if let existing = openSessions.first(where: { $0.resumeId == entry.id }) {
            select(.session(existing.id))
            return existing
        }
        return openNew(
            directory: entry.projectDirectory,
            resumeId: entry.id,
            sessionTitle: entry.title,
            permissionMode: permissionMode ?? CanopySettings.shared.defaultPermissionMode,
            customApi: ModelProviderStore.selectedProvider()
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
    func openCloud(_ session: RemoteSession, permissionMode: PermissionMode? = nil) {
        let mode = permissionMode ?? CanopySettings.shared.defaultPermissionMode
        Task { await openCloudAsync(session, permissionMode: mode) }
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

    private func openCloudAsync(_ session: RemoteSession, permissionMode: PermissionMode) async {
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
        // around (and don't shift the Cmd+1..9 row indices).
        openSessions.append(opened)
        // Drop the cloud row immediately so the sidebar reflects the new
        // state without waiting for the next /v1/sessions poll.
        cloud.removeAll { $0.id == session.id }
        select(.session(opened.id))
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

        if case .session(let sel) = selection, sel == id {
            // Browser-tab convention: focus the row that took the closed
            // tab's slot (i.e. what was just to its right), or the new
            // last row if we closed the rightmost. `lastActiveAt` would
            // jump to whichever was opened most recently regardless of
            // proximity, which feels random when closing the active row.
            if openSessions.isEmpty {
                selection = .launcher
            } else {
                let target = idx < openSessions.count ? idx : openSessions.count - 1
                selection = .session(openSessions[target].id)
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
        // UI-supplied offsets: reject out-of-range input instead of letting
        // Array.move trap. (IndexSet can't hold negatives, so max() covers
        // the from side.)
        guard (fromOffsets.max() ?? -1) < visible.count,
              toOffset >= 0, toOffset <= visible.count else {
            return master
        }
        var newVisible = visible
        newVisible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard newVisible != visible else { return master }
        let visibleSet = Set(visible)
        var iterator = newVisible.makeIterator()
        return master.map { id in
            visibleSet.contains(id) ? (iterator.next() ?? id) : id
        }
    }

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

    // MARK: - Panes

    /// Replace focused pane's content with the given session. If panes is
    /// empty (fresh launch, no selection yet) create the first pane at
    /// paneDefaultWidth.
    func openInFocusedPane(_ sessionId: OpenSession.ID) {
        guard openSessions.contains(where: { $0.id == sessionId }) else { return }
        if panes.isEmpty {
            panes = [PaneSlot(content: .session(sessionId), preferredWidth: Self.paneDefaultWidth)]
            focusedPaneIndex = 0
            selection = .session(sessionId)
            Task { @MainActor in PaneWindowSizer.applyForCurrentPanes(store: self) }
            return
        }
        // If this session already lives in a pane, focus that one instead of
        // duplicating (one session, one pane invariant).
        if let idx = paneIndex(forSession: sessionId) {
            focusedPaneIndex = idx
            selection = .session(sessionId)
            return
        }
        panes[focusedPaneIndex].content = .session(sessionId)
        selection = .session(sessionId)
    }

    /// Replace focused pane's content with the launcher. Used by Cmd+N in
    /// multi-pane mode; single-pane Cmd+N routes through select(.launcher).
    func openLauncherInFocusedPane() {
        if panes.isEmpty {
            selection = .launcher
            return
        }
        panes[focusedPaneIndex].content = .launcher
        selection = .launcher
    }

    /// Append a new pane for `sessionId`. Returns false if bounced (already
    /// in a pane — caller should visually flash the existing pane — or cap
    /// reached — caller should show the "Maximum 5 panes" hint).
    @discardableResult
    func openInNewPane(_ sessionId: OpenSession.ID) -> Bool {
        guard openSessions.contains(where: { $0.id == sessionId }) else { return false }
        if let existing = paneIndex(forSession: sessionId) {
            focusedPaneIndex = existing
            selection = .session(sessionId)
            return false
        }
        guard panes.count < Self.paneAbsoluteCap else { return false }
        let width = focusedPane?.preferredWidth ?? Self.paneDefaultWidth
        panes.append(PaneSlot(content: .session(sessionId), preferredWidth: width))
        focusedPaneIndex = panes.count - 1
        selection = .session(sessionId)
        Task { @MainActor in PaneWindowSizer.applyForCurrentPanes(store: self) }
        return true
    }

    /// Append a new launcher pane. Returns false only when the cap is reached.
    @discardableResult
    func openLauncherInNewPane() -> Bool {
        guard panes.count < Self.paneAbsoluteCap else { return false }
        let width = focusedPane?.preferredWidth ?? Self.paneDefaultWidth
        panes.append(PaneSlot(content: .launcher, preferredWidth: width))
        focusedPaneIndex = panes.count - 1
        selection = .launcher
        Task { @MainActor in PaneWindowSizer.applyForCurrentPanes(store: self) }
        return true
    }

    /// Close the pane at `index`. Focus shifts to the left neighbor (or 0
    /// if the closed pane was leftmost). The underlying OpenSession stays
    /// in openSessions — closing a pane does not close the session.
    func closePane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        // Browser-tab convention (matches closeSession): only shift focus when
        // the closed pane WAS the focused one. Closing a non-focused pane
        // keeps focus on the same underlying pane; we just adjust the index
        // if the removal shifted it down.
        let wasFocused = index == focusedPaneIndex
        panes.remove(at: index)
        if panes.isEmpty {
            focusedPaneIndex = 0
            selection = .launcher
            Task { @MainActor in PaneWindowSizer.applyForCurrentPanes(store: self) }
            return
        }
        if wasFocused {
            focusedPaneIndex = max(0, min(index - 1, panes.count - 1))
        } else if index < focusedPaneIndex {
            focusedPaneIndex -= 1
        }
        switch panes[focusedPaneIndex].content {
        case .session(let id): selection = .session(id)
        case .launcher: selection = .launcher
        }
        Task { @MainActor in PaneWindowSizer.applyForCurrentPanes(store: self) }
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
        switch panes[next].content {
        case .session(let id): selection = .session(id)
        case .launcher: selection = .launcher
        }
    }

    /// Update two adjacent panes' preferred widths from a divider drag.
    /// Sum is preserved by the caller; floor is enforced here.
    func setAdjacentPaneWidths(leftIndex: Int, leftWidth: CGFloat, rightWidth: CGFloat) {
        let rightIndex = leftIndex + 1
        guard panes.indices.contains(leftIndex), panes.indices.contains(rightIndex) else { return }
        let floor = Self.paneMinDragWidth
        guard leftWidth >= floor, rightWidth >= floor else { return }
        panes[leftIndex].preferredWidth = leftWidth
        panes[rightIndex].preferredWidth = rightWidth
    }

    /// Called by closeSession(_:) after the session is removed from
    /// openSessions. Drops any pane pointing at the closed session.
    private func removePanesForClosedSession(_ id: OpenSession.ID) {
        let matching = panes.enumerated().compactMap { (i, slot) -> Int? in
            if case .session(let sid) = slot.content, sid == id { return i } else { return nil }
        }
        // Remove from the highest index down so earlier indices stay valid.
        for idx in matching.reversed() { closePane(at: idx) }
    }

    #if DEBUG
    /// Probe-only seeding helper. `openSessions` is `private(set)` (setter
    /// file-private), so `_SidebarLogicProbe` cannot assign it directly.
    func _probeSeedOpenSessions(_ sessions: [OpenSession]) {
        openSessions = sessions
    }
    #endif
}
