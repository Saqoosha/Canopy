import Foundation

/// When the daemon stops a session nobody is using. A stopped session can be
/// resumed from Recents, and a running shim (node + CLI) costs hundreds of MB,
/// so the limit is short.
enum SessionReaper {
    static let defaultIdleLimit: TimeInterval = 15 * 60

    struct Inputs: Equatable {
        /// Clients attached to this session right now.
        let attachedClients: Int
        /// `isBusy(working:permissionPending:asking:backgroundTasks:)`.
        let isBusy: Bool
        /// The later of: the last client detaching, the last turn ending.
        let quietSince: Date
        /// The phone opened it. The phone's list is its Open
        /// block and has no pane to hold the session, so this stands in for one:
        /// it runs until someone stops it, as a Mac pane's session does.
        var heldOpen = false
    }

    /// Busy means stopping would lose something: a turn, a question, or a
    /// tracked background task still running after its turn ended.
    static func isBusy(working: Bool, permissionPending: Bool, asking: Bool, backgroundTasks: Int) -> Bool {
        working || permissionPending || asking || backgroundTasks > 0
    }

    static func shouldReap(_ inputs: Inputs, now: Date, limit: TimeInterval) -> Bool {
        guard inputs.attachedClients == 0, !inputs.isBusy, !inputs.heldOpen else { return false }
        return now.timeIntervalSince(inputs.quietSince) >= limit
    }
}
