import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionReaper")

/// When the daemon stops a session nobody is using. A running shim (node + CLI)
/// costs 300-400 MB (measured with `footprint`); a stopped one keeps its Open row
/// on the Mac (`ReapedSessions`) and resumes on click. The limit is
/// `CanopySettings.sessionIdleLimitMinutes`.
enum SessionReaper {
    struct Inputs: Equatable {
        /// Clients attached to this session right now.
        let attachedClients: Int
        /// `isBusy(working:permissionPending:asking:backgroundTasks:)`.
        let isBusy: Bool
        /// The later of: the last client detaching, the last turn ending.
        let quietSince: Date
        /// Something stands in for a pane (`ShimProcess.reaperHolds`): the phone, until Stop, or a `listen`.
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

/// The sessions the reaper stopped, as the rows they had. Sent to GUIs as
/// `session_state`'s `reaped`, so each keeps (or rebuilds) a dormant Open row that
/// resumes on click, instead of the session dropping into Recents. A Stop takes
/// one out, and so does the session running again. Persisted, so a daemon restart
/// for an update does not drop the rows. Callers insert only sessions that have a
/// transcript: nothing else can be resumed.
@MainActor @Observable
final class ReapedSessions {
    static let shared = ReapedSessions()
    static let defaultsKey = "canopy.daemon.reapedSessions.v2"
    /// Oldest first; the oldest go once the list is full.
    static let capacity = 200

    private(set) var rows: [ControlProtocol.SessionRow]
    private let defaults: UserDefaults?

    /// nil `defaults` keeps it in memory only.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = defaults?.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? []
        rows = stored.compactMap(ControlProtocol.SessionRow.init(wire:))
    }

    func insert(_ row: ControlProtocol.SessionRow) {
        var next = rows.filter { !Self.same($0, row) }
        next.append(row)
        if next.count > Self.capacity {
            logger.notice("reaped list is full; dropping the \(next.count - Self.capacity) oldest, whose rows leave Open")
            next.removeFirst(next.count - Self.capacity)
        }
        write(next)
    }

    /// Removes the rows any of `refs` names; false when none did.
    @discardableResult
    func remove(_ refs: [ControlProtocol.SessionRef]) -> Bool {
        let next = rows.filter { row in !refs.contains { Self.names($0, row) } }
        guard next.count != rows.count else { return false }
        write(next)
        return true
    }

    private static func same(_ a: ControlProtocol.SessionRow, _ b: ControlProtocol.SessionRow) -> Bool {
        a.resumeId == b.resumeId || (a.key != nil && a.key == b.key)
    }

    private static func names(_ ref: ControlProtocol.SessionRef, _ row: ControlProtocol.SessionRow) -> Bool {
        switch ref {
        case .key(let key): return row.key == key
        case .resumeId(let id): return row.resumeId.lowercased() == id
        }
    }

    private func write(_ next: [ControlProtocol.SessionRow]) {
        rows = next
        defaults?.set(next.map(\.wire), forKey: Self.defaultsKey)
    }
}
