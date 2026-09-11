import AppKit
import SwiftUI

/// Sidebar list with switchable grouping mode (segmented picker):
///   - Date: Today / Yesterday / This Week / This Month / Older
///   - Project: one section per project, most-recent-first
///   - Env: Local / Cloud
/// Open sessions always stay in their own "Open" block regardless of mode.
/// Grouping mode persists across launches via UserDefaults.
///
/// Click semantics:
///   - .open (Cmd or not) → openInFocusedPane. Cmd is deliberately ignored
///     on open rows; see handleRowClick for why
///   - .closedLocal + plain → openLocal (select → openInFocusedPane)
///   - .closedLocal + Cmd   → openLocal, then openInNewPane
///   - .closedCloud + plain → openCloud(.focused)
///   - .closedCloud + Cmd   → openCloud(.newPane)
///   - × (Open rows only) → stop the shim, drop the session, select the next
///     most-recent open or fall back to launcher
struct Sidebar: View {
    @Bindable var store: SessionStore
    @State private var hoveredRowId: String?
    @State private var showFilterPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Top: + New session + grouping mode + filter gear
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    newSessionButton
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    filterButton
                }
                groupingModePicker
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // The `selection:` binding exists ONLY to receive clicks on open
            // rows: any tap gesture on a row (even .simultaneousGesture)
            // claims mouse-down and kills List's .onMove row dragging on
            // macOS (FB7367473 family), so open rows must be click-handled
            // through native selection instead. The binding always reads
            // nil so the system never paints its own selection highlight —
            // we keep painting the active row ourselves for contrast
            // control. Closed rows are .selectionDisabled and keep a plain
            // tap gesture (they don't drag, and routing them through
            // selection would also fire on right-click).
            List(selection: rowClickBinding) {
                let rows = store.visibleRows
                let openRows = rows.filter(\.isOpen)
                let closedRows = rows.filter { !$0.isOpen }
                let closedSections = SidebarGrouping.sections(from: closedRows, mode: store.groupingMode)

                if !openRows.isEmpty {
                    Section("Open") {
                        ForEach(openRows, id: \.id) { row in
                            rowView(row)
                        }
                        .onMove { from, to in
                            store.moveOpenRows(fromOffsets: from, toOffset: to)
                        }
                    }
                }
                ForEach(closedSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.rows, id: \.id) { row in
                            rowView(row)
                        }
                    }
                }
                // A launcher pane always contributes a row, so `rows.isEmpty`
                // stopped being reachable while one is open — and with it the
                // "No sessions yet." / "No sessions match your filter." state,
                // which is exactly when a user needs the Clear-filters button.
                // Ask whether anything but launcher rows is showing instead.
                if SessionStore.holdsOnlyLauncherRows(rows) {
                    Section {
                        emptyStateView
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            // Animate the open block's row order. Rows now move on their own
            // in cases the user didn't drag — a click pulling a session's row
            // down to its pane's rank, or a launcher row following its pane —
            // and an instant jump there reads as a glitch rather than as the
            // sidebar re-syncing.
            //
            // Keyed on the open block's ROW ids, not on `openSessions`: a
            // launcher row moves while `openSessions` is untouched, so the
            // session-only key left exactly the rows this feature added
            // snapping into place.
            //
            // Scoped to the row ORDER on purpose. The panes are deliberately
            // NOT animated: animating pane geometry drifts the embedded
            // WKWebView's scroll position, which is why PaneWindowSizer
            // resizes the window in one synchronous frame instead.
            .animation(.easeInOut(duration: 0.2), value: openRowIdentity)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Compensate for `.listStyle(.sidebar)`'s built-in side padding.
            // Rows still don't touch the wall, but not for the reason an older
            // note here gave: it credited the chip with a "6px inset" of its
            // own, which was a fair reading of the 3pt-per-side padding the
            // background used to take. That padding is gone, and
            // `RowChip.horizontalInset` is NEGATIVE — the chip deliberately
            // extends 4pt PAST the List's content area to sit under the
            // system's row ring. The sidebar's own edge is what keeps it off
            // the wall now.
            .padding(.horizontal, -8)
            // Auto-scroll-to-top when a new session is opened, via an
            // AppKit hook below. SwiftUI's `ScrollViewProxy.scrollTo` on
            // a freshly inserted row tripped a precondition crash on
            // every layout strategy we tried.
            .background {
                ListScrollToTop(trigger: store.openSessions.count)
            }

            SidebarAccountSection()
        }
        .overlay(alignment: .bottom) {
            if let err = store.teleportError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        store.dismissTeleportError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.teleportError)
        .task {
            store.isSidebarVisible = true
            await store.refreshRecents()
            await store.refreshCloud()
            store.startCloudPolling()
        }
        .onDisappear {
            store.isSidebarVisible = false
            store.stopCloudPolling()
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(alignment: .center, spacing: 8) {
            if store.filter.isActive {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No sessions match your filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear filters") {
                    store.filter = SidebarFilter()
                }
                .controlSize(.small)
            } else {
                Image(systemName: "bubble.left")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Click \"+ New session\" to start.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var groupingModePicker: some View {
        Picker("Group by", selection: $store.groupingMode) {
            ForEach(GroupingMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
    }

    private var filterButton: some View {
        Button {
            showFilterPopover.toggle()
        } label: {
            Image(systemName: store.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(store.filter.isActive ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("Filter sessions")
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
            FilterPopover(store: store)
        }
    }

    private var newSessionButton: some View {
        Button {
            // Mirror Cmd+N (CanopyApp File > New Session). Cmd+click opens
            // a launcher in a new pane (spec parity with sidebar row Cmd+click).
            if NSEvent.modifierFlags.contains(.command) {
                if !store.openLauncherInNewPane() {
                    store.showCapReachedHintOnFocusedPane()
                }
            } else if store.panes.isEmpty {
                store.select(.launcher)
            } else {
                store.openLauncherInFocusedPane()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("New session")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            // Only while no pane exists at all. Once a launcher has a pane it
            // has a row, and the row carries the highlight — painting both
            // reads as two selected things.
            store.selection == .launcher && store.panes.isEmpty
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// Click receiver for open rows. Always reads nil (no system selection
    /// highlight ever sticks); a write means "the user clicked this row".
    /// Cmd is read atomically here — it may be released before any follow-up.
    private var rowClickBinding: Binding<String?> {
        Binding(
            get: { nil },
            set: { newValue in
                guard let id = newValue,
                      let row = store.visibleRows.first(where: { $0.id == id }) else { return }
                let cmdHeld = NSEvent.modifierFlags.contains(.command)
                handleRowClick(row: row, addNewPane: cmdHeld)
            }
        )
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        SidebarRowView(
            row: row,
            isHovered: hoveredRowId == row.id,
            isActive: isActive(row),
            isTeleporting: isTeleporting(row),
            isUnread: isUnread(row),
            onClose: { handleClose(row) }
        )
        // Dimmed, not hidden: the session is still real and its log is still
        // readable — the row is how you reach it. `.opacity` rather than a
        // foreground style so the icon and every label fade together.
        .opacity(canOpen(row) ? 1 : 0.45)
        .help(canOpen(row)
            ? ""
            : "This session's folder is gone — typically a worktree removed after merging. "
                + "It can't be reopened while the folder is missing. "
                + "Right-click to copy its log path and read it from another session.")
        .background(
            // BOTH backgrounds live here, inline, because `.listRowBackground`
            // stretches its content to fill the cell and eats any inset
            // modifier — a rounded rect handed to it renders as a full-bleed
            // square. The pane highlight sits under the hover fill so hovering
            // a paned row deepens it instead of replacing it.
            //
            // Drawn flush to the cell, with NO padding of its own: both
            // insets are taken by `.listRowInsets` below, so the chip IS the
            // cell. That is what puts the chip under the system ring a
            // right-click leaves behind — see `RowChip` for why the ring is
            // the thing that cannot move.
            ZStack {
                RoundedRectangle(cornerRadius: RowChip.cornerRadius)
                    .fill(paneHighlightFill(for: row))
                RoundedRectangle(cornerRadius: RowChip.cornerRadius)
                    .strokeBorder(paneHighlightStroke(for: row), lineWidth: 1)
                RoundedRectangle(cornerRadius: RowChip.cornerRadius)
                    .fill(rowBackgroundFill(for: row))
            }
        )
        .id(row.id)
        .onHover { h in hoveredRowId = h ? row.id : nil }
        .contentShape(Rectangle())
        // Closed rows: plain tap to open. Open rows: NO gesture — any tap
        // gesture here (even simultaneous) blocks .onMove dragging; their
        // clicks arrive via the List's rowClickBinding instead.
        // An unopenable row keeps NO tap gesture: the click would reach
        // `ShimProcess.start`'s missing-cwd refusal and end in a pane that
        // opens and closes again, which is worse than nothing happening beside
        // a visibly disabled row. Right-click still works.
        .gesture(row.isOpen || !canOpen(row) ? nil : TapGesture().onEnded {
            let cmdHeld = NSEvent.modifierFlags.contains(.command)
            handleRowClick(row: row, addNewPane: cmdHeld)
        })
        .selectionDisabled(!row.isOpen)
        .contextMenu { rowMenu(for: row) }
        // Cleared deliberately: everything visible is drawn by the inline
        // `.background` above, where insets survive.
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: 1 + RowChip.verticalInset,
            leading: RowChip.horizontalInset,
            bottom: 1 + RowChip.verticalInset,
            trailing: RowChip.horizontalInset
        ))
    }

    @ViewBuilder
    private func rowMenu(for row: SidebarRow) -> some View {
        // Exhaustive rather than two `if case`s: a new row kind must decide
        // whether it can be renamed instead of silently inheriting "no".
        // Cloud titles belong to the server, and a launcher has no session.
        switch row {
        case .open, .closedLocal:
            Button("Rename…") { store.beginRename(row: row) }
        case .closedCloud, .launcher:
            EmptyView()
        }
        if case .open(let s) = row {
            Button("Restart session") { store.restartSession(s.id) }
            Button("Close session") { store.closeSession(s.id) }
        }
        if case .launcher = row {
            Button("Close pane") { handleClose(row) }
        }
        // Only where a local folder exists to open: a remote session's
        // directory is on the other machine, a cloud row has none until it is
        // teleported, and a launcher has no session. Absent rather than
        // disabled — a greyed row reads as "not right now", and for these it
        // is never.
        if let directory = finderDirectory(for: row) {
            Divider()
            Button("Open in Finder") { store.openInFinder(directory) }
        }
        // The one action that still works for a session whose worktree was
        // removed: hand its log to another session to read. Absent rather than
        // disabled, for the reason the Finder item above gives — and absent on
        // a brand-new session too, whose placeholder id resolves to no file.
        if let logPath = sessionLogPath(for: row) {
            Button("Copy Session Log Path") { store.copyToPasteboard(logPath) }
        }
        Button("Hide from sidebar") {
            store.hideClosedSession(rowId: row.id)
        }
        // Open rows and launcher rows both stand for something live; hiding
        // one would take a pane off the map without closing it.
        .disabled(row.isOpen)
    }

    /// Whether clicking a row can actually produce a session.
    ///
    /// Only a closed local row can answer no, and only because the directory
    /// it recorded is gone (`SessionEntry.canOpen`, measured once by
    /// `loadAllSessions` rather than per render). Every other kind either has
    /// a live pane already, is fetched from the server, or is a launcher.
    private func canOpen(_ row: SidebarRow) -> Bool {
        SidebarRow.canOpen(row)
    }

    /// The session log a row's "Copy Session Log Path" should copy, or nil
    /// when the row carries none.
    ///
    /// Read straight off the entry — see `SessionEntry.logPath` for why it
    /// must not be looked up here. Closed local rows only: an open session's
    /// conversation is already on screen, and buying its path would cost the
    /// lookup this exists to avoid.
    private func sessionLogPath(for row: SidebarRow) -> String? {
        switch row {
        case .closedLocal(let entry): return entry.logPath
        case .open, .closedCloud, .launcher: return nil
        }
    }

    /// The local folder a row's "Open in Finder" should open, or nil when the
    /// row has none. Open rows use the session's SPAWN directory, which is
    /// what `SessionStore.openInFinder` documents and what the pane header's
    /// copy of this menu passes too.
    private func finderDirectory(for row: SidebarRow) -> URL? {
        switch row {
        case .open(let s):
            return s.origin.remoteHost == nil ? s.origin.workingDirectory : nil
        case .closedLocal(let entry):
            // Gone means gone: offering Finder a directory we already know is
            // absent can only log a warning and look like nothing happened.
            return entry.canOpen ? entry.projectDirectory : nil
        case .closedCloud, .launcher:
            return nil
        }
    }

    /// Hover fill only — the top layer of the inline `.background` ZStack.
    /// Pane membership is the layer beneath it, `paneHighlightFill(for:)`.
    private func rowBackgroundFill(for row: SidebarRow) -> Color {
        if hoveredRowId == row.id { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    /// Neutral and deliberately pale, sharing `Color.primary` with the hover
    /// fill above it. The row's activity dot is the only thing in the sidebar
    /// carrying a *meaning* in its hue, so the surface under it stays achromatic
    /// — an accent-tinted fill both darkened the row and competed with the dot's
    /// own colour, and the low-saturation states (idle grey most of all) lost.
    /// Fill says only "this row has a pane" — focused and unfocused panes share
    /// it exactly, and `paneHighlightStroke(for:)` is the *whole* of what marks
    /// the focused one. Splitting the distinction across both meant the focused
    /// fill had to be the darker of two shades, which is the contrast the dot
    /// pays for; an outline costs it nothing.
    private func paneHighlightFill(for row: SidebarRow) -> Color {
        switch highlight(for: row) {
        case .none: Color.clear
        case .weak, .strong: Color.primary.opacity(0.06)
        }
    }

    /// Focused pane only — an outline reads as "this one" without darkening the
    /// surface the dot has to sit on.
    private func paneHighlightStroke(for row: SidebarRow) -> Color {
        switch highlight(for: row) {
        case .none, .weak: Color.clear
        case .strong: Color.primary.opacity(0.28)
        }
    }

    /// Animation key for the open block. This re-runs the whole `visibleRows`
    /// pipeline — dedup, sort, filter, interleave — since that property caches
    /// nothing and the List body's own `rows` is a different evaluation. Kept
    /// anyway: keying on `panes` + the session order would miss a launcher
    /// sliding to a new anchor because the VISIBLE session set changed (a
    /// filter edit, a hide) while neither of those did.
    private var openRowIdentity: [String] {
        store.visibleRows.filter(\.isOpen).map(\.id)
    }

    private func isActive(_ row: SidebarRow) -> Bool {
        switch (row, store.selection) {
        case (.open(let s), .session(let id)): return s.id == id
        // A launcher row IS its pane, so "active" can only mean "that pane has
        // focus" — `selection == .launcher` says nothing about which one when
        // two launcher panes are open.
        case (.launcher(let slot), _): return store.focusedPane?.id == slot
        default: return false
        }
    }

    private func isTeleporting(_ row: SidebarRow) -> Bool {
        guard let id = store.teleportingCloudId,
              case .closedCloud(let s) = row else { return false }
        return s.id == id
    }

    private func isUnread(_ row: SidebarRow) -> Bool {
        if case .open(let s) = row { return store.unreadSessionIds.contains(s.id) }
        return false
    }

    private enum PaneHighlightLevel { case none, weak, strong }

    private func highlight(for row: SidebarRow) -> PaneHighlightLevel {
        let idx: Int?
        switch row {
        case .open(let session): idx = store.paneIndex(forSession: session.id)
        // Always paned — a launcher row exists only because its pane does.
        case .launcher(let slot): idx = store.paneIndex(forSlot: slot)
        case .closedLocal, .closedCloud: idx = nil
        }
        guard let idx else { return .none }
        return idx == store.focusedPaneIndex ? .strong : .weak
    }

    private func handleRowClick(row: SidebarRow, addNewPane: Bool) {
        switch row {
        case .open(let session):
            // Cmd+click gives the row its own pane, and that pane lands at the
            // row's position — top row, leftmost pane. The gesture points at
            // the ROW, so the row is what holds still; `openInNewPane` sorts
            // the new pane into place rather than parking it on the right end.
            // (A plain click points at the focused PANE instead, so there the
            // row is what moves. Whichever the user aimed at stays put.)
            // Clicking a row is a deliberate act on that session, and it has
            // to be recorded HERE: when the session already occupies the
            // focused pane, neither of the MacroPad's other two stamp routes
            // fires (the pane-click monitor never sees a click this far left,
            // and `openInFocusedPane` takes its focus-only branch), so the
            // green dot the user just clicked would keep burning. See
            // `MacroPadController.noteInteraction(sessionId:)`.
            //
            // Unconditional on purpose, above the Cmd branch: the
            // already-focused case is why it exists, and on every other route
            // it is a duplicate the strictly-greater comparison makes
            // harmless. Narrowing it to the case the paragraph above
            // describes is the edit not to make.
            MacroPadController.shared?.noteInteraction(sessionId: session.id)
            if addNewPane {
                if store.panes.count >= SessionStore.paneAbsoluteCap,
                   store.paneIndex(forSession: session.id) == nil {
                    store.showCapReachedHintOnFocusedPane()
                }
                // Falls through to focusing the existing pane when the session
                // already has one, and to a no-op at the cap.
                _ = store.openInNewPane(session.id)
            } else {
                store.openInFocusedPane(session.id)
            }
        case .launcher(let slot):
            // The launcher is already in a pane, so there is nothing to load
            // and nothing for Cmd to add — a click can only mean "focus it".
            if let idx = store.paneIndex(forSlot: slot) {
                store.setFocusedPaneIndex(idx)
            }
        case .closedLocal(let entry):
            if addNewPane && store.panes.count >= SessionStore.paneAbsoluteCap {
                store.showCapReachedHintOnFocusedPane()
                _ = store.openLocal(entry, target: .focused)  // deliberate: user still gets the session, just in focused
            } else {
                _ = store.openLocal(entry, target: addNewPane ? .newPane : .focused)
            }
        case .closedCloud(let cloud):
            if addNewPane && store.panes.count >= SessionStore.paneAbsoluteCap {
                store.showCapReachedHintOnFocusedPane()
                store.openCloud(cloud, target: .focused)
            } else {
                store.openCloud(cloud, target: addNewPane ? .newPane : .focused)
            }
        }
    }

    private func handleClose(_ row: SidebarRow) {
        switch row {
        case .open(let s):
            store.closeSession(s.id)
        case .launcher(let slot):
            // Closes the pane, not a session — there is no session behind it.
            if let idx = store.paneIndex(forSlot: slot) {
                store.closePane(at: idx)
            }
        case .closedLocal, .closedCloud:
            break
        }
    }
}

/// Geometry of the rounded chip a sidebar row draws itself as.
///
/// The two insets are `.listRowInsets` values, and the chip is drawn flush to
/// the cell they produce. That indirection is the whole point: the system ring
/// a right-click leaves on a row traces the **table row**, which no SwiftUI
/// modifier moves and which `contentShape(.contextMenuPreview, …)` cannot
/// reshape either (iOS-only). So the only way to make the two agree is to put
/// the chip where the ring already is — and the ring is where AppKit puts a
/// sidebar row's highlight, which is the native look anyway.
///
/// **`horizontalInset` and `cornerRadius` are measurements of the ring, not
/// design choices.** They come from an ASCII pixel map of the TOP-LEFT corner
/// of a right-clicked row on macOS 26, classifying each device pixel as
/// background / ring / chip stroke / chip fill, **on a 2x display** — the
/// device-pixel counts below are halved to points on that assumption and were
/// never checked at another backing scale. Re-measure the same way if a macOS
/// release moves them, and measure a corner from its TANGENT rows: a 45°
/// diagonal through the corner is the one place where two different radii
/// still read as touching, so it makes any radius look correct.
///
/// `verticalInset` is **not** a measurement of anything. It is the 1pt the
/// background's own `.padding(.vertical, 1)` used to take, relocated out to
/// `listRowInsets` and subtracted back out of `SidebarRowView`. The chip's top
/// edge and height come out identical either way; vertically the chip and the
/// ring already agreed, which is why only the horizontal inset had to move.
///
/// - `horizontalInset` is **negative**: the ring's inner edge sits 12pt from
///   the window's left edge while a List row's default content area starts at
///   16, so a zero inset still leaves a 4pt band of background inside the
///   ring. Only the LEADING edge was measured; the trailing −4 assumes the
///   ring is symmetric about the List's content area, which one corner cannot
///   show. If the right edge ever looks wrong, that assumption is where to
///   look first.
/// - `cornerRadius` is the radius of the ring's INNER rect, read off a pixel
///   map of one corner. **Do not derive it as "outer radius minus stroke
///   width" — the ring is not a stroked path.** Measured: the outer arc spans
///   13 device px and the inner arc 12.5, a difference of 0.5px against a band
///   4px thick, so the two contours are near-identical curves 2pt apart rather
///   than concentric arcs. Deriving it gave 5.5 and then 4.5, both visibly too
///   square; the chip's border pulled away from the blue around the corner
///   while the straight edges stayed flush. The chip is drawn UNDER the ring,
///   so too small only shows as that pull-away, while too large (it was 9)
///   opens a real background gap at each corner — the two failures look
///   different, and only the second one has a name.
///
/// `SidebarRowView`'s content padding subtracts both insets, so the text and
/// icons stay exactly where they were when the inset lived inside the
/// background.
private enum RowChip {
    static let cornerRadius: CGFloat = 6.25
    static let horizontalInset: CGFloat = -4
    static let verticalInset: CGFloat = 1
}

// MARK: - Filter popover

private struct FilterPopover: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "Status") {
                Picker("", selection: $store.filter.status) {
                    ForEach(SidebarFilter.StatusFilter.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            row(label: "Origin") {
                Picker("", selection: $store.filter.origin) {
                    ForEach(SidebarFilter.OriginFilter.allCases, id: \.self) { o in
                        Text(o.displayName).tag(o)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            row(label: "Project") {
                Picker("", selection: projectBinding) {
                    Text("All").tag(String?.none)
                    ForEach(store.allProjects, id: \.self) { p in
                        Text(p).tag(String?.some(p))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            row(label: "Last activity") {
                Picker("", selection: $store.filter.lastActivity) {
                    ForEach(SidebarFilter.LastActivityFilter.allCases, id: \.self) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            Divider()
            Button("Clear filters") {
                store.filter = SidebarFilter()
            }
            .disabled(!store.filter.isActive)
            .controlSize(.small)
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content()
        }
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { store.filter.project },
            set: { store.filter.project = $0 }
        )
    }
}

// MARK: - Row

private struct SidebarRowView: View {
    let row: SidebarRow
    let isHovered: Bool
    let isActive: Bool
    let isTeleporting: Bool
    let isUnread: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13, weight: titleWeight))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Directly under the title, above the project: a peer name is
                // read while deciding which session to message, so every open
                // row is a candidate and the names want to form a column the
                // eye can run down. The project line is read once, when the
                // session is opened, so it takes the bottom slot.
                //
                // Only an open row can have one — a closed session has no
                // process and so no entry in `~/.claude/sessions` — which is
                // what keeps Recents at their current two-line height.
                if let peerName {
                    PeerNameChip(name: peerName)
                        .padding(.top, 1)
                        // Hang the border so the chip's TEXT keeps the column
                        // the title and project lines make; without it the
                        // chip's own padding indents the middle line by
                        // `textInset` and breaks the straight edge that is the
                        // whole reason the name sits on its own line here.
                        .padding(.leading, -PeerNameChip.textInset)
                }
                // A launcher row has no project, and an empty Text would still
                // reserve the second line's height. `displayProject`, not
                // `project`: the latter is the filter and grouping key and must
                // not carry the branch.
                if !row.displayProject.isEmpty {
                    Text(row.displayProject)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if shouldShowClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(closeColor)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(closeHelp)
            }
        }
        // Padding INSIDE the chip, stated as the ORIGINAL distance from the
        // List cell minus whatever `RowChip` now takes outside this view. So
        // the text and icons land where they always did, whatever the insets
        // are set to — including the negative horizontal one, where this
        // padding grows to keep the content still while the chip widens.
        .padding(.leading, 10 - RowChip.horizontalInset)
        .padding(.trailing, 6 - RowChip.horizontalInset)
        .padding(.vertical, 4 - RowChip.verticalInset)
        .frame(minHeight: 36 - 2 * RowChip.verticalInset)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        if isTeleporting {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if case .open(let session) = row {
            ActivityDot(activity: SessionActivity.of(session, isUnread: isUnread))
        } else {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: openIconSize, weight: openIconWeight))
                .foregroundStyle(iconTint)
        }
    }

    private var openIconSize: CGFloat {
        switch row {
        case .open: return 6 // small filled dot for idle open
        case .launcher: return 12
        case .closedLocal, .closedCloud: return 14
        }
    }

    private var openIconWeight: Font.Weight {
        switch row {
        case .open: return .regular
        // Matches the "+" on the New session button above the list.
        case .launcher: return .medium
        case .closedLocal, .closedCloud: return .regular
        }
    }

    private var iconName: String {
        switch row {
        // Unreachable: `iconView` routes every open row to `ActivityDot`.
        // Kept so the switch stays exhaustive.
        case .open: return "circle.fill"
        case .launcher: return "plus"
        case .closedLocal: return "desktopcomputer"
        case .closedCloud: return "cloud"
        }
    }

    /// Subtle gray active-row background → text stays in normal colors.
    private var iconTint: Color {
        switch row {
        case .open:
            // Idle-open dot: muted secondary — not an attention grab.
            return .secondary
        case .launcher, .closedLocal, .closedCloud:
            return .secondary
        }
    }

    /// Active row gets a slightly heavier title to telegraph selection on
    /// top of the gray pill.
    private var titleWeight: Font.Weight {
        if isActive { return .semibold }
        switch row {
        case .open, .launcher: return .medium
        case .closedLocal, .closedCloud: return .regular
        }
    }

    private var titleColor: Color {
        switch row {
        case .open: return .primary
        case .launcher: return .secondary
        case .closedLocal, .closedCloud: return .secondary
        }
    }

    /// Nil for every row but `.open`: `PeerNameStore` is keyed by the
    /// `sessionId` of a *running* CLI, and a closed row has none.
    private var peerName: String? {
        guard case .open(let session) = row else { return nil }
        return PeerNameStore.shared.name(forResumeId: session.resumeId)
    }

    private var subtitleColor: Color { .secondary }

    private var closeColor: Color { .secondary }

    private var shouldShowClose: Bool {
        guard row.isOpen else { return false }
        return isHovered
    }

    private var closeHelp: String {
        if case .launcher = row { return "Close pane" }
        return "Close session"
    }
}

/// Drops into the List's background hierarchy and scrolls the enclosing
/// NSScrollView to the top whenever `trigger` increases. Side-steps
/// `ScrollViewReader.scrollTo`, which has a precondition crash if the
/// target id isn't already laid out — racy for freshly inserted rows.
private struct ListScrollToTop: NSViewRepresentable {
    let trigger: Int

    final class Coordinator {
        var lastTrigger: Int = 0
        weak var hostView: NSView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.hostView = v
        context.coordinator.lastTrigger = trigger
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        guard trigger > coord.lastTrigger else {
            coord.lastTrigger = trigger
            return
        }
        coord.lastTrigger = trigger
        // Resolve the enclosing NSScrollView (List uses NSScrollView under
        // the hood). May not be available immediately on first layout, so
        // we async to next runloop tick.
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView ?? findScrollView(near: nsView) else { return }
            // Animate to top: clipView origin (0,0) maps to top in default
            // (non-flipped) coordinates is wrong; for NSScrollView with a
            // documentView, scroll(.zero) on the contentView clips to top.
            let topPoint = NSPoint(x: 0, y: 0)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(topPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Walk up the view hierarchy looking for an NSScrollView. SwiftUI
    /// sometimes nests our background view several levels above the
    /// scroll view we want.
    private func findScrollView(near view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let scroll = v as? NSScrollView { return scroll }
            for sub in v.subviews {
                if let scroll = findScrollViewDescendant(of: sub) {
                    return scroll
                }
            }
            current = v.superview
        }
        return nil
    }

    private func findScrollViewDescendant(of view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews {
            if let s = findScrollViewDescendant(of: sub) { return s }
        }
        return nil
    }
}

// MARK: - Sidebar grouping

/// Ordered sections produced by a grouping mode. Each mode guarantees a
/// stable, deterministic order:
///   - .date: Today → Yesterday → This Week → This Month → Older
///   - .project: most-recent-first (by max lastModified per project)
///   - .env: Local → Cloud
/// Use `sections(from:mode:)`.
struct SidebarGrouping {
    let title: String
    let rows: [SidebarRow]

    static func sections(from rows: [SidebarRow], mode: GroupingMode) -> [SidebarGrouping] {
        guard !rows.isEmpty else { return [] }
        switch mode {
        case .date:
            let groups = DateGroup.grouped(rows)
            return DateGroup.allCases.compactMap { group in
                groups[group].map { SidebarGrouping(title: group.rawValue, rows: $0) }
            }
        case .project:
            let grouped = Dictionary(grouping: rows) { $0.project }
            return grouped.map { SidebarGrouping(title: $0.key, rows: $0.value) }
                .sorted { a, b in
                    let aMax = a.rows.map(\.lastModified).max() ?? .distantPast
                    let bMax = b.rows.map(\.lastModified).max() ?? .distantPast
                    return aMax > bMax
                }
        case .env:
            let locals = rows.filter { $0.origin == .local }
            let clouds = rows.filter { $0.origin == .cloud }
            var result: [SidebarGrouping] = []
            if !locals.isEmpty { result.append(SidebarGrouping(title: "Local", rows: locals)) }
            if !clouds.isEmpty { result.append(SidebarGrouping(title: "Cloud", rows: clouds)) }
            return result
        }
    }
}

// MARK: - Date grouping

/// Groups closed-sidebar rows into the same buckets Claude Desktop uses
/// (as of 2026-05).
enum DateGroup: String, Comparable, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case older = "Older"

    private var rank: Int {
        switch self {
        case .today: 0
        case .yesterday: 1
        case .thisWeek: 2
        case .thisMonth: 3
        case .older: 4
        }
    }

    static func < (lhs: DateGroup, rhs: DateGroup) -> Bool {
        lhs.rank < rhs.rank
    }

    static func classify(_ date: Date, now: Date = Date()) -> DateGroup {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        return .older
    }

    /// Group rows by date, keyed by DateGroup. Returns an empty dictionary
    /// when given no rows (not an empty `.older` group).
    static func grouped(_ rows: [SidebarRow]) -> [DateGroup: [SidebarRow]] {
        guard !rows.isEmpty else { return [:] }
        return Dictionary(grouping: rows) { classify($0.lastModified) }
    }
}

