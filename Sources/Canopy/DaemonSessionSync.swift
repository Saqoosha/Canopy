import Foundation

/// Reconciles the GUI's open local sessions with the daemon's `session_state`.
/// Pure: the probe drives it without a daemon.
enum DaemonSessionSync {
    struct Local: Equatable {
        let id: UUID
        let key: String?
        let resumeId: String
        /// A paned session is never removed by a push: its pane shows the drop,
        /// and Retry resumes it if the daemon lost it (a restart, a stop elsewhere).
        let isPaned: Bool
    }

    struct Update: Equatable {
        let id: UUID
        let row: ControlProtocol.SessionRow
    }

    struct Plan: Equatable {
        var updates: [Update] = []
        var adds: [ControlProtocol.SessionRow] = []
        var removes: [UUID] = []
    }

    /// A row and a local session are the same when their keys match, or else when
    /// their resumeIds do — a key from a daemon that has since restarted is stale.
    /// `complete` is false when some rows could not be read; then nothing is removed.
    static func plan(rows: [ControlProtocol.SessionRow], local: [Local], complete: Bool = true) -> Plan {
        var plan = Plan()
        var matched = Set<UUID>()
        var pending: [ControlProtocol.SessionRow] = []
        for row in rows where row.key != nil {
            if let hit = local.first(where: { !matched.contains($0.id) && $0.key != nil && $0.key == row.key }) {
                matched.insert(hit.id)
                plan.updates.append(Update(id: hit.id, row: row))
            } else {
                pending.append(row)
            }
        }
        for row in pending {
            if let hit = local.first(where: { !matched.contains($0.id) && $0.resumeId == row.resumeId }) {
                matched.insert(hit.id)
                plan.updates.append(Update(id: hit.id, row: row))
            } else {
                plan.adds.append(row)
            }
        }
        if complete {
            plan.removes = local.filter { !matched.contains($0.id) && !$0.isPaned }.map(\.id)
        }
        return plan
    }
}
