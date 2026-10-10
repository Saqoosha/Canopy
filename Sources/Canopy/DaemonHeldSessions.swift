import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonHeldSessions")

/// Sessions the phone or the control API opened, carried across a daemon restart.
///
/// The daemon restores nothing else across a restart: a session with a client
/// attached comes back when that client re-attaches with `open`. A held session
/// may have no client at all, so nothing would ask for it. What comes back is the
/// open row under its old key, its CLI resumed with `--resume`.
struct DaemonHeldSessions: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// The old `OpenSession.id`, reused so a phone re-attaching by key finds the row.
        var key: String
        var resumeId: String
        var directory: String
        var title: String
        var model: String?
        var effort: String?
        var permissionMode: PermissionMode
        /// Ids only: `ModelProvider.authToken` is a secret.
        var providerId: String?
        var accountId: String?
        /// Absent in a file written before control sessions were carried: those were all the phone's.
        var heldByPhone: Bool?
        var openedByControl: Bool?
    }

    var entries: [Entry]
    var savedAt: Date

    /// A file older than this is from a restart whose daemon never came up; restoring it
    /// later could run a second CLI on a transcript the app has since resumed itself.
    static let maxAge: TimeInterval = 10 * 60

    /// Held or control-opened, local, and resumable. `hasTranscript` is a parameter so the
    /// probe does not touch the disk; a session with no transcript yet cannot be resumed.
    static func capture(_ sessions: [OpenSession], now: Date = Date(),
                        hasTranscript: (OpenSession, URL) -> Bool) -> DaemonHeldSessions {
        DaemonHeldSessions(entries: sessions.compactMap { session in
            guard session.heldOpenByPhone || session.openedByControl, case .local(let dir) = session.origin,
                  hasTranscript(session, dir) else { return nil }
            return Entry(key: session.id.uuidString, resumeId: session.resumeId, directory: dir.path,
                         title: session.title, model: session.model, effort: session.effortLevel,
                         permissionMode: session.permissionMode, providerId: session.customApi?.id,
                         accountId: session.claudeAccount?.id, heldByPhone: session.heldOpenByPhone,
                         openedByControl: session.openedByControl)
        }, savedAt: now)
    }

    static var fileURL: URL {
        let bundleId = Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Canopy", isDirectory: true)
            .appendingPathComponent("daemon-held-\(bundleId).json")
    }

    func save(to url: URL = fileURL) {
        guard !entries.isEmpty else { return }
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            logger.notice("saved \(entries.count, privacy: .public) held session(s) for the restart")
        } catch {
            logger.error("could not save held sessions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read and delete. Deleted first, so a restore that crashes the daemon
    /// is not replayed on every launch.
    static func consume(from url: URL = fileURL, now: Date = Date()) -> DaemonHeldSessions? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        do {
            let held = try JSONDecoder().decode(DaemonHeldSessions.self, from: data)
            guard now.timeIntervalSince(held.savedAt) <= maxAge else {
                logger.notice("dropped \(held.entries.count, privacy: .public) held session(s) saved \(Int(now.timeIntervalSince(held.savedAt)), privacy: .public)s ago")
                return nil
            }
            return held
        } catch {
            logger.error("held sessions file unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
