import Foundation

/// How closed sidebar rows are grouped into sections.
enum GroupingMode: String, CaseIterable {
    case date = "Date"
    case project = "Project"
    case env = "Env"
}

/// One row in the sidebar list. Four flavours, all unified by Identifiable +
/// Hashable so `List(selection:)` can target any of them.
///
/// Sort order across a mixed array of rows:
///   1. all `.open` first (any origin), in insertion order (newest at
///      the bottom — browser-tab convention)
///   2. all closed rows (`.closedLocal` + `.closedCloud`) mixed, by
///      `lastModified` desc
///
/// Use `SidebarRow.sorted(_:)` to apply this consistently.
///
/// `.launcher` is the odd one out and deliberately so: it is the only case
/// with no session behind it, and it exists purely to keep the Open block
/// readable as a map of the pane strip. A launcher pane used to have no row
/// at all, which broke that correspondence exactly when a launcher was open.
/// It carries a `PaneSlot.ID` rather than an index so it survives the pane
/// strip being re-ordered under it, and it is NOT produced by
/// `SessionStore.visibleRows`' own pipeline — it is interleaved in afterwards
/// by `SessionStore.interleavingLaunchers(into:panes:)`, which is what keeps
/// it out of `filter.apply` — a live pane the sidebar filter can hide would
/// put the map back where it started. (`deduped` drops only `.closedCloud`
/// rows and `hiddenIds` is applied to `recents`/`cloud` before any row is
/// built, so neither could ever have touched it.)
enum SidebarRow: Identifiable, Hashable {
    case open(OpenSession)
    case closedLocal(SessionEntry)
    case closedCloud(RemoteSession)
    /// A launcher pane, keyed by the `PaneSlot.ID` it renders.
    case launcher(PaneSlot.ID)

    var id: String {
        switch self {
        case .open(let s): "open:\(s.id.uuidString)"
        case .closedLocal(let e): "local:\(e.id)"
        case .closedCloud(let r): "cloud:\(r.id)"
        case .launcher(let slot): "launcher:\(slot.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .open(let s): s.title
        case .closedLocal(let e): e.title
        case .closedCloud(let r): r.summary
        case .launcher: "New Session"
        }
    }

    /// The project a row belongs to — **the filter and grouping key, never the
    /// rendered subtitle**. `SidebarFilter.apply(to:)` compares it,
    /// `SidebarFilter.projects(in:)` builds the picker's options from it, and
    /// `Sidebar`'s `.project` grouping buckets on it, so anything that varies
    /// within one repository must stay out: appending the branch here splits
    /// one project into a bucket and a picker entry per branch. Use
    /// `displayProject` for anything the user reads.
    var project: String {
        switch self {
        case .open(let s):
            return s.project
        case .closedLocal(let e):
            return e.projectName
        case .closedCloud(let r):
            if let owner = r.repoOwner, let name = r.repoName {
                return "\(owner)/\(name)"
            }
            return r.repoName ?? "—"
        case .launcher:
            // Empty rather than a placeholder: `SidebarRowView` drops the
            // subtitle line entirely when this is empty, so the launcher row
            // doesn't reserve space for a second line it has nothing to say on.
            return ""
        }
    }

    /// What the row's subtitle actually shows. Identical to `project` except
    /// for an open session, which appends the branch its VCS reports so two
    /// panes on two branches of one repo are distinguishable. Deliberately a
    /// second property rather than a change to `project`: the two answers
    /// serve opposite needs — grouping wants the coarsest label that still
    /// names the repo, the subtitle wants the finest one that names the work.
    var displayProject: String {
        if case .open(let s) = self { return s.projectLabel }
        return project
    }

    /// Drives the closed-block sort order only. The open block ignores
    /// this field — it's sorted by insertion order in `sorted(_:)`.
    /// `.open` rows still expose `lastActiveAt` here so dedup / filter
    /// helpers can read a date from any row variant.
    var lastModified: Date {
        switch self {
        case .open(let s): s.lastActiveAt
        case .closedLocal(let e): e.timestamp
        case .closedCloud(let r): r.lastModified
        // Never consulted, by two separate mechanisms. `sorted(_:)`'s closed
        // block excludes `isOpen` rows itself, and `SidebarGrouping` only ever
        // sees closed rows because its single call site hands it `closedRows`
        // (`Sidebar.swift`) — it filters nothing of its own, so a future caller
        // passing every row would reach this. Only `SidebarFilter.apply`'s
        // lastActivity cutoff depends on running before the interleave.
        case .launcher: .distantFuture
        }
    }

    /// "Belongs in the Open section", not "is an OpenSession" — a launcher
    /// row answers true here and matches no `case .open` pattern anywhere.
    /// Every consumer that wants a session still pattern-matches `.open`, so
    /// widening this doesn't silently hand them a row with no session.
    var isOpen: Bool {
        switch self {
        case .open, .launcher: true
        case .closedLocal, .closedCloud: false
        }
    }

    /// The row's "kind" for filtering: was this session born locally or in
    /// the cloud? An open session counts as `.local` (it lives here now); a
    /// closed cloud session counts as `.cloud`.
    enum Origin: String, CaseIterable, Hashable, Sendable {
        case local
        case cloud
    }

    var origin: Origin {
        switch self {
        case .open: .local
        case .launcher: .local
        case .closedLocal: .local
        case .closedCloud: .cloud
        }
    }

    /// Apply the canonical sort: open first **in insertion order** (newest
    /// at the bottom, browser-tab convention), then closed rows mixed
    /// (local + cloud) by lastModified desc.
    static func sorted(_ rows: [SidebarRow]) -> [SidebarRow] {
        let open = rows.filter { $0.isOpen } // preserve input order
        let closed = rows
            .filter { !$0.isOpen }
            .sorted { $0.lastModified > $1.lastModified }
        return open + closed
    }

    /// De-dup: drop any `.closedCloud` whose id appears in the local
    /// `teleportedFromMap` (keyed by local jsonl id, value = remote cloud id).
    /// Also drop cloud rows duplicated by an `.open` whose origin is
    /// `.teleportedFrom(...)`.
    static func deduped(
        _ rows: [SidebarRow],
        teleportedFromMap: [String: String]
    ) -> [SidebarRow] {
        let teleportedCloudIds = Set(teleportedFromMap.values)
        let openTeleportedCloudIds = Set(
            rows.compactMap { row -> String? in
                if case .open(let s) = row { return s.teleportedFromCloudId }
                return nil
            }
        )
        let drop = teleportedCloudIds.union(openTeleportedCloudIds)
        return rows.filter { row in
            if case .closedCloud(let r) = row { return !drop.contains(r.id) }
            return true
        }
    }
}
