import SwiftUI

/// Sidebar list with switchable grouping mode (segmented picker):
///   - Date: Today / Yesterday / This Week / This Month / Older
///   - Project: one section per project, most-recent-first
///   - Env: Local / Cloud
/// Open sessions always stay in their own "Open" block regardless of mode.
/// Grouping mode persists across launches via UserDefaults.
///
/// Click semantics:
///   - .open       → select that session
///   - .closedLocal → spawn a shim with --resume, then select
///   - .closedCloud → run the teleport flow, then select the resulting open row
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

            // No `selection:` binding — we paint our own active-row
            // background so we control the contrast and never end up
            // with the system's gray-on-white when the app loses focus.
            List {
                let rows = store.visibleRows
                let openRows = rows.filter(\.isOpen)
                let closedRows = rows.filter { !$0.isOpen }
                let closedSections = SidebarGrouping.sections(from: closedRows, mode: store.groupingMode)

                if !openRows.isEmpty {
                    Section("Open") {
                        ForEach(openRows, id: \.id) { row in
                            rowView(row)
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
                if rows.isEmpty {
                    Section {
                        emptyStateView
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Compensate for `.listStyle(.sidebar)`'s built-in side
            // padding. The pill bg has its own 6px inset already so
            // rows still don't touch the wall, just the wider gutter.
            .padding(.horizontal, -8)
            // Auto-scroll-to-top when a new session is opened, via an
            // AppKit hook below. SwiftUI's `ScrollViewProxy.scrollTo` on
            // a freshly inserted row tripped a precondition crash on
            // every layout strategy we tried.
            .background {
                ListScrollToTop(trigger: store.openSessions.count)
            }
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
            store.select(.launcher)
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
            store.selection == .launcher
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        SidebarRowView(
            row: row,
            isHovered: hoveredRowId == row.id,
            isActive: isActive(row),
            isTeleporting: isTeleporting(row),
            onClose: { handleClose(row) }
        )
        .background(
            // Inline so the padding actually shows. `.listRowBackground` stretches
            // its content to fill the cell, eating any inset modifiers.
            RoundedRectangle(cornerRadius: 9)
                .fill(rowBackgroundFill(for: row))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
        )
        .id(row.id)
        .onHover { h in hoveredRowId = h ? row.id : nil }
        .contentShape(Rectangle())
        .onTapGesture { handleClick(row) }
        .contextMenu { rowMenu(for: row) }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }

    @ViewBuilder
    private func rowMenu(for row: SidebarRow) -> some View {
        switch row {
        case .open(let s):
            Button("Close session") { store.closeSession(s.id) }
        case .closedLocal, .closedCloud:
            Button("Hide from sidebar") {
                store.hideClosedSession(rowId: row.id)
            }
        }
    }

    private func rowBackgroundFill(for row: SidebarRow) -> Color {
        if isActive(row) { return Color.primary.opacity(0.07) }
        if hoveredRowId == row.id { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    private func isActive(_ row: SidebarRow) -> Bool {
        switch (row, store.selection) {
        case (.open(let s), .session(let id)): return s.id == id
        default: return false
        }
    }

    private func isTeleporting(_ row: SidebarRow) -> Bool {
        guard let id = store.teleportingCloudId,
              case .closedCloud(let s) = row else { return false }
        return s.id == id
    }


    private func handleClick(_ row: SidebarRow) {
        switch row {
        case .open(let s):
            store.select(.session(s.id))
        case .closedLocal(let entry):
            store.openLocal(entry)
        case .closedCloud(let session):
            store.openCloud(session)
        }
    }

    private func handleClose(_ row: SidebarRow) {
        if case .open(let s) = row {
            store.closeSession(s.id)
        }
    }
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
                Text(row.project)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                .help("Close session")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        if isSpawning || isTeleporting {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if isAsking {
            // Asking wins over thinking: AskUserQuestion / permission
            // prompts pause Claude, the user MUST act, so a static
            // raised-hand reads as "your turn" louder than the spinner.
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundStyle(SidebarPalette.askingYellow)
        } else if isThinking {
            ThinkingFlower()
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
        case .closedLocal, .closedCloud: return 14
        }
    }

    private var openIconWeight: Font.Weight {
        switch row {
        case .open: return .regular
        case .closedLocal, .closedCloud: return .regular
        }
    }

    private var isSpawning: Bool {
        if case .open(let s) = row { return s.status == .spawning }
        return false
    }

    private var isThinking: Bool {
        if case .open(let s) = row { return s.isThinking }
        return false
    }

    private var isAsking: Bool {
        if case .open(let s) = row { return s.isAsking }
        return false
    }

    private var iconName: String {
        switch row {
        case .open: return "circle.fill" // small filled dot — "alive but idle"
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
        case .closedLocal, .closedCloud:
            return .secondary
        }
    }

    /// Active row gets a slightly heavier title to telegraph selection on
    /// top of the gray pill.
    private var titleWeight: Font.Weight {
        if isActive { return .semibold }
        switch row {
        case .open: return .medium
        case .closedLocal, .closedCloud: return .regular
        }
    }

    private var titleColor: Color {
        switch row {
        case .open: return .primary
        case .closedLocal, .closedCloud: return .secondary
        }
    }

    private var subtitleColor: Color { .secondary }

    private var closeColor: Color { .secondary }

    private var shouldShowClose: Bool {
        guard case .open = row else { return false }
        return isHovered
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

private enum SidebarPalette {
    /// Matches `--app-claude-orange` in the CC extension's webview CSS.
    static let claudeOrange = Color(red: 0.85, green: 0.46, blue: 0.34)
    /// Soft amber for "asking" state — warmer than system yellow, calmer
    /// than orange. Reads as "your attention please" without screaming.
    static let askingYellow = Color(red: 0.95, green: 0.74, blue: 0.18)
}

/// Animated 6-petal flower shown while Claude is generating a response.
/// Cycles through Unicode glyphs (✻ ✺ ✷ ✹ ✶ ❋) at ~6 fps in Claude orange.
private struct ThinkingFlower: View {
    private static let frames = ["✻", "✺", "✷", "✹", "✶", "❋"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { context in
            let idx = Int(context.date.timeIntervalSince1970 * 6) % Self.frames.count
            Text(Self.frames[idx])
                .font(.system(size: 16))
                .foregroundStyle(SidebarPalette.claudeOrange)
        }
    }
}
