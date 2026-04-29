import Foundation

/// One row in the sidebar list. Three flavours, all unified by Identifiable +
/// Hashable so `List(selection:)` can target any of them.
///
/// Sort order across a mixed array of rows:
///   1. all `.open` first (any origin), in insertion order (newest at
///      the bottom — browser-tab convention)
///   2. all closed rows (`.closedLocal` + `.closedCloud`) mixed, by
///      `lastModified` desc
///
/// Use `SidebarRow.sorted(_:)` to apply this consistently.
enum SidebarRow: Identifiable, Hashable {
    case open(OpenSession)
    case closedLocal(SessionEntry)
    case closedCloud(RemoteSession)

    var id: String {
        switch self {
        case .open(let s): "open:\(s.id.uuidString)"
        case .closedLocal(let e): "local:\(e.id)"
        case .closedCloud(let r): "cloud:\(r.id)"
        }
    }

    var title: String {
        switch self {
        case .open(let s): s.title
        case .closedLocal(let e): e.title
        case .closedCloud(let r): r.summary
        }
    }

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
        }
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
        }
    }

    var isOpen: Bool {
        if case .open = self { return true }
        return false
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
