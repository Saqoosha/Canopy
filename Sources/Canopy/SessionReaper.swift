import Foundation

/// When the daemon stops a session nobody is using. A running shim (node + CLI)
/// costs 300-400 MB (measured with `footprint`); a stopped one keeps its Open row
/// on the Mac (`ReapedSessions`) and resumes on click. The limit is
/// `CanopySettings.sessionIdleLimitMinutes`.
enum SessionReaper {
    static let defaultIdleLimit = TimeInterval(CanopySettings.defaultSessionIdleLimitMinutes * 60)

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

/// The sessions the reaper stopped, by resumeId. Sent to GUIs as `session_state`'s
/// `reaped`, so their Open rows stay (dormant, resumable on click) instead of
/// dropping into Recents. Only a Stop takes one out. Persisted, so a daemon
/// restart for an update does not drop the rows.
@MainActor @Observable
final class ReapedSessions {
    static let shared = ReapedSessions()
    static let defaultsKey = "canopy.daemon.reapedSessions.v1"
    /// Oldest first; the oldest go once the list is full.
    static let capacity = 200

    private(set) var ids: [String]
    private let defaults: UserDefaults?

    /// nil `defaults` keeps it in memory only (the probe).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        ids = defaults?.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func insert(_ id: String) {
        var next = ids.filter { $0 != id }
        next.append(id)
        if next.count > Self.capacity { next.removeFirst(next.count - Self.capacity) }
        write(next)
    }

    func remove(_ id: String) {
        guard ids.contains(id) else { return }
        write(ids.filter { $0 != id })
    }

    private func write(_ next: [String]) {
        ids = next
        defaults?.set(next, forKey: Self.defaultsKey)
    }
}
