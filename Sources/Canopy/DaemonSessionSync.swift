import Foundation

/// Reconciles the GUI's open local sessions with the daemon's `session_state`.
/// Pure: the probe drives it without a daemon.
enum DaemonSessionSync {
    struct Local: Equatable {
        let id: UUID
        let key: String?
        let resumeId: String
        /// In a pane and not attached yet: the daemon may not list it until the attach lands.
        let awaitingAttach: Bool
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

    /// A row and a local session are the same when their keys match, or — for a
    /// local session that has no key yet — when their resumeIds do.
    static func plan(rows: [ControlProtocol.SessionRow], local: [Local]) -> Plan {
        var plan = Plan()
        var matched = Set<UUID>()
        for row in rows where row.key != nil {
            let hit = local.first { !matched.contains($0.id) && $0.key != nil && $0.key == row.key }
                ?? local.first { !matched.contains($0.id) && $0.key == nil && $0.resumeId == row.resumeId }
            if let hit {
                matched.insert(hit.id)
                plan.updates.append(Update(id: hit.id, row: row))
            } else {
                plan.adds.append(row)
            }
        }
        plan.removes = local.filter { !matched.contains($0.id) && !$0.awaitingAttach }.map(\.id)
        return plan
    }
}
