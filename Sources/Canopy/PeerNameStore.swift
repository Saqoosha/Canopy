import Foundation
import Observation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "PeerName")

/// The name other Claude Code sessions use to message this one — what
/// `ListAgents` prints and `/rename` changes.
///
/// The CLI publishes one file per live session at
/// `~/.claude/sessions/<pid>.json`, holding its `sessionId`, its `name`, and
/// where the name came from. Canopy only reads them; nothing here writes to
/// that directory.
///
/// Two properties of that directory shape this type. **A file exists only
/// while its session is alive** — the CLI removes it on exit — so an absent
/// entry means "not running", never "unnamed", and a closed sidebar row
/// legitimately has no peer name to show. And **a rename rewrites a file in
/// place**, which a directory watch cannot see: `vnode` events fire on the
/// directory for adds and removes, and an in-place write to a file inside it
/// touches neither. That is why the watch is paired with a poll rather than
/// trusted on its own — the watch makes a new session appear at once, and the
/// poll is what makes `/rename` land.
@MainActor
@Observable
final class PeerNameStore {
    static let shared = PeerNameStore()

    /// Live peer names keyed by the CLI's `sessionId` — the same string an
    /// `OpenSession` carries as `resumeId`. Only sessions running right now
    /// appear here.
    private(set) var namesBySessionId: [String: String] = [:]

    /// How often the directory is re-read to catch an in-place rename. Cheap
    /// enough to leave running: the directory holds one small file per live
    /// session, and the read itself runs off the main actor.
    private static let pollInterval: Duration = .seconds(3)

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private init() {
        savedNames = Self.loadSavedNames()
    }

    /// The peer name for a session, or nil when that session is not currently
    /// running under a name Canopy can see.
    func name(forResumeId resumeId: String) -> String? {
        guard !resumeId.isEmpty else { return nil }
        return namesBySessionId[resumeId]
    }

    /// Idempotent — safe to call from a `.task` that can re-run.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        startWatching()
        startPolling()
    }

    // MARK: - Reading

    private func refresh() {
        Task.detached(priority: .utility) {
            // nil means the directory could not be listed at all. Holding the
            // last good map is the whole point — see `readDirectory`.
            guard let map = Self.readDirectory() else { return }
            await MainActor.run { Self.shared.apply(map) }
        }
    }

    /// `@Observable` notifies on every assignment, equal or not, and this
    /// runs on a timer — so an unconditional store would redraw every sidebar
    /// row and pane header a few times a minute for nothing.
    /// Remembering runs BEFORE the equality guard: a name can already be on
    /// screen and still not be in the store yet, which is exactly the state
    /// right after launch.
    private func apply(_ live: [String: LiveName]) {
        rememberPinnedNames(in: live)
        let names = live.mapValues { $0.name }
        guard names != namesBySessionId else { return }
        logger.notice("peer names: \(names.count, privacy: .public) live session(s)")
        namesBySessionId = names
    }

    /// One record of `~/.claude/sessions/<pid>.json`. Deliberately a subset:
    /// the file also carries a socket path, a protocol version and a feature
    /// list that Canopy has no use for, and decoding fields nobody reads
    /// would make an unrelated CLI change break the names.
    private struct Record: Decodable {
        let sessionId: String
        let name: String?
        /// Epoch milliseconds. Read only to break a duplicate-`sessionId`
        /// tie; see `readDirectory`.
        let startedAt: Double?
        /// `"user"`, `"derived"`, `"collision"`, or absent. See `isPinned`.
        let nameSource: String?
    }

    /// One live session's published name, as read off disk.
    struct LiveName: Equatable {
        let name: String
        /// `"user"`, `"derived"`, `"collision"`, or nil. See `isPinned`.
        let nameSource: String?
    }

    /// Whether a published name should outlive the process that published it.
    ///
    /// `nameSource` takes four states, three of them measured on 2.1.239:
    /// `"user"` after a `/rename`, `"derived"` for a name the CLI generated
    /// from the cwd, and ABSENT when the name arrived in
    /// `CLAUDE_CODE_SESSION_NAME`. `"collision"` appears in the binary beside
    /// `"derived"` and is treated the same here; it was not reproduced.
    ///
    /// (An earlier version of this comment claimed the field is written ONLY
    /// for `derived`/`collision`. That over-generalised a single grep hit —
    /// one write path spells the others `void 0` — and under it `"user"`
    /// would be unreachable and this whole type would persist nothing.)
    ///
    /// Only `"user"` pins. **An absent source deliberately does not**, and the
    /// reason is worth stating because the opposite looks necessary: a name
    /// Canopy restored comes back with no `nameSource`, so it seems it must be
    /// re-pinned or it would be forgotten. It would not. `savedNames` is never
    /// pruned below the cap, so the entry that drove the restore is still
    /// there and drives the next one too. Pinning the absent case buys
    /// nothing and costs a real bug: `CLAUDE_CODE_SESSION_NAME` is set on the
    /// shim once and inherited by every CLI it spawns afterwards, so a
    /// `/clear` or `/resume` republishes that name under a DIFFERENT
    /// sessionId — which would then be persisted as if the user had chosen
    /// it.
    nonisolated static func isPinned(nameSource: String?) -> Bool {
        nameSource == "user"
    }

    private nonisolated static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Whole-directory read, or nil when the directory itself could not be
    /// listed.
    ///
    /// **The nil case is not an empty result and must not be collapsed into
    /// one.** `apply` commits whatever it is handed, so returning `[:]` on a
    /// failed listing blanks every chip in the sidebar and every pane header
    /// — the exact opposite of the per-file resilience below, and
    /// indistinguishable on screen from "nothing is running". A directory
    /// that legitimately holds no sessions lists successfully and returns an
    /// empty map, so the two stay distinguishable. What holding the last good
    /// map costs is stale chips if `~/.claude/sessions` is deleted outright;
    /// that is an installation-level fault, a transient listing failure is
    /// not, and only one of the two happens during ordinary use.
    ///
    /// A malformed or half-written FILE is still skipped rather than failing
    /// the batch — the CLI writes these while Canopy is reading them, and one
    /// unreadable file must not blank every other session's name.
    ///
    /// **Two files can carry the same `sessionId`.** Canopy SIGKILLs
    /// surviving CLI descendants at teardown (`ShimProcess`), and a SIGKILLed
    /// CLI never removes its own `<pid>.json` — so reopening that session
    /// leaves a stale record beside the live one. `contentsOfDirectory` has
    /// no defined order, so with no tiebreak the dead process's name could
    /// win permanently and a later `/rename` would never appear. Newest
    /// `startedAt` wins; a record missing the field loses to any record that
    /// has one, since a file old enough to predate it is the likelier
    /// leftover.
    private nonisolated static func readDirectory() -> [String: LiveName]? {
        let dir = sessionsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var best: [String: (startedAt: Double, live: LiveName)] = [:]
        for url in entries where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let record = try? JSONDecoder().decode(Record.self, from: data),
                let name = record.name,
                !name.isEmpty
            else { continue }
            let startedAt = record.startedAt ?? -.greatestFiniteMagnitude
            if let existing = best[record.sessionId], existing.startedAt >= startedAt { continue }
            best[record.sessionId] = (startedAt, LiveName(name: name, nameSource: record.nameSource))
        }
        return best.mapValues { $0.live }
    }

    /// Read and apply the directory synchronously.
    ///
    /// For the one caller that cannot wait for the next poll: `ShimProcess`
    /// is about to stop a CLI, and stopping it deletes the record. A
    /// `/rename` is an in-place write that fires no directory event, so the
    /// name is seen only by the poll — and closing the session inside that
    /// window would take the record away before it was ever observed, losing
    /// exactly the rename this type exists to keep. Everything else goes
    /// through `refresh`, which reads off the main actor.
    func captureNow() {
        guard let map = Self.readDirectory() else { return }
        apply(map)
    }

    // MARK: - Remembering across restarts

    /// A name lives only as long as the CLI process that published it — the
    /// record is deleted on exit — so without this a `/rename` is lost the
    /// next time Canopy launches, and the CLI generates a fresh `derived`
    /// name. Keyed by `sessionId`, so a session gets its own name back and
    /// only its own.
    private static let storeKey = "peerNames.v1"

    /// A ceiling against unbounded growth, not a working limit: reaching it
    /// takes a thousand separately renamed sessions, and a full store is about
    /// 80 KB.
    ///
    /// The cap is set high precisely because the trim order is imperfect and
    /// cannot easily be made better. `savedAt` is when the name was last
    /// SET, not when the session was last used, so at the cap a daily-driver
    /// session renamed months ago would be evicted before a session renamed
    /// yesterday and never opened again — losing exactly the name this feature
    /// exists to keep. Touching `savedAt` on read was the obvious repair and
    /// was rejected: it turns every session spawn into a UserDefaults write,
    /// and "spawned" is not "used" either, so it buys an imperfect order at
    /// the cost of a new write path.
    private static let maxStoredNames = 1000

    private struct StoredName: Codable {
        let name: String
        let savedAt: Date
    }

    @ObservationIgnored private var savedNames: [String: StoredName] = [:]

    /// The name to hand a CLI at spawn for this session, if one was ever set.
    /// `ShimProcess` reads this; nothing on screen does.
    func savedName(forSessionId sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        return savedNames[sessionId]?.name
    }

    /// A corrupt blob degrades to empty and is then overwritten by the next
    /// save — deliberately unlike `SessionTitleStore`, which parks the bytes
    /// and refuses to write. The stakes differ: a lost title leaves a sidebar
    /// row unreadable with no way to recover it, while a lost peer name just
    /// means the CLI generates one and you rename again.
    private static func loadSavedNames() -> [String: StoredName] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredName].self, from: data)) ?? [:]
    }

    private func rememberPinnedNames(in live: [String: LiveName]) {
        var changed = false
        for (sessionId, entry) in live {
            guard Self.isPinned(nameSource: entry.nameSource) else { continue }
            guard savedNames[sessionId]?.name != entry.name else { continue }
            savedNames[sessionId] = StoredName(name: entry.name, savedAt: Date())
            changed = true
        }
        guard changed else { return }

        if savedNames.count > Self.maxStoredNames {
            let doomed = savedNames
                .sorted { $0.value.savedAt < $1.value.savedAt }
                .prefix(savedNames.count - Self.maxStoredNames)
            for (key, _) in doomed { savedNames.removeValue(forKey: key) }
        }
        guard let data = try? JSONEncoder().encode(savedNames) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
        logger.notice("peer names remembered: \(self.savedNames.count, privacy: .public)")
    }

    // MARK: - Watching

    /// Best effort. The directory does not exist until a session with peer
    /// messaging has run at least once, and `O_EVTONLY` on a missing path
    /// simply fails — the poll covers that case, so a failed watch is a log
    /// line and not an error path.
    private func startWatching() {
        let dir = Self.sessionsDirectory
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.notice("no directory watch: \(dir.path, privacy: .private) unavailable")
            return
        }
        let source = Self.makeWatcher(fd: fd)
        source.resume()
        watcher = source
    }

    /// `nonisolated` is load-bearing, not tidiness. `DispatchSourceHandler`
    /// is a plain `@convention(block) () -> Void` — **not** `@Sendable` — so a
    /// closure literal written inside this `@MainActor` type inherits its
    /// isolation, and the compiler emits a main-queue assertion at the
    /// closure's entry. The source runs on a utility queue, so the first
    /// directory event aborts the process with
    /// `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue
    /// [com.apple.main-thread]`. Measured, not theorised: it took down a debug
    /// build the instant a new session's file appeared. Writing the handlers
    /// from a `nonisolated` context removes the inference and the check.
    ///
    /// This is the same trap `ShimProcess` documents; see the closure-literal
    /// entry in Key Learnings (General).
    private nonisolated static func makeWatcher(fd: CInt) -> DispatchSourceFileSystemObject {
        // `.write` alone, deliberately. `.delete` / `.rename` / `.revoke`
        // report the watched directory itself going away, and nothing here
        // can act on that: the descriptor is already bound to the dead inode,
        // so re-arming means tearing the source down and reopening a path
        // that may not exist yet — a retry loop needing its own backoff, to
        // cover a state the poll already degrades to gracefully. Listing
        // those events and then ignoring them reads as coverage this does not
        // have.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            Task { @MainActor in PeerNameStore.shared.refresh() }
        }
        source.setCancelHandler {
            close(fd)
        }
        return source
    }

    private func startPolling() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                PeerNameStore.shared.refresh()
            }
        }
    }
}

/// The peer name as it appears in the sidebar and in a pane header: a small
/// outlined monospace chip.
///
/// Monospace because these are identifiers, not prose — `canopy-40` and
/// `canopy-4o` have to be distinguishable at 10.5pt. Deliberately NOT styled
/// by `nameSource`: a chip that changes weight when the name was set by
/// `/rename` breaks the one thing the sidebar placement buys, which is a
/// column the eye can run straight down.
struct PeerNameChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Peer name \(name)")
    }
}
