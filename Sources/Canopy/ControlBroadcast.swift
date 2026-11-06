import Foundation

/// Frames for this Mac's own GUI that no reply can carry: a skill asks the daemon, the daemon
/// asks the GUI. TCP clients never register, so another Mac cannot reach this.
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

    /// Sends to every subscribed local client. Returns how many received it.
    @discardableResult
    static func toLocalClients(_ frame: [String: Any]) -> Int {
        entries.removeAll { $0.session == nil }
        entries.forEach { $0.session?.push(frame) }
        return entries.count
    }
}
