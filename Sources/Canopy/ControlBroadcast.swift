import Foundation

/// Frames for this Mac's GUI that no reply can carry: a skill asks the daemon, the daemon asks
/// the GUI. Any local connection that subscribes gets them, and today that is only the GUI. TCP
/// connections never register. One-way: no acknowledgement, and no replay after a reconnect.
@MainActor
enum ControlBroadcast {
    private final class Entry {
        weak var session: ControlSession?
        init(_ session: ControlSession) { self.session = session }
    }

    private static var entries: [Entry] = []

    static func register(_ session: ControlSession) {
        entries.append(Entry(session))
    }

    static func unregister(_ session: ControlSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
    }

    static var hasLocalSubscribers: Bool {
        entries.contains { $0.session != nil }
    }

    /// Sends to every subscribed local connection, and returns how many there are. A frame can
    /// still be lost with a connection that is going down.
    static func toLocalSubscribers(_ frame: [String: Any]) -> Int {
        entries.removeAll { $0.session == nil }
        entries.forEach { $0.session?.push(frame) }
        return entries.count
    }
}
