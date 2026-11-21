import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "JobWatcher")

/// A job as `canopyctl job watch` registers it. Keyed by the session's `resumeId`,
/// which survives a daemon restart.
struct JobSpec: Codable, Equatable {
    let resumeId: String
    let label: String
    /// Prints `N/M`, or with `total`, a count.
    let probe: String
    /// Run the probe over ssh on this host; nil runs it here.
    let host: String?
    let total: Int?
    let interval: TimeInterval
    let stallMinutes: Double?
}

/// One job's readings. Pure, so the probe can drive it with made-up output.
struct JobTrack: Codable, Equatable {
    static let keepSeconds: TimeInterval = 4 * 3600

    var spec: JobSpec
    var samples: [JobSample] = []
    var failures = 0
    var note: String?

    init(spec: JobSpec) { self.spec = spec }

    /// Folds one probe run in. Output without a count is a failure, never `done = 0`.
    mutating func record(output: String?, exitStatus: Int32, at now: Date) {
        if exitStatus == 0, let output, let count = JobEstimator.parse(output, total: spec.total) {
            samples.append(JobSample(at: now, done: count.done, total: count.total))
            samples.removeAll { now.timeIntervalSince($0.at) > Self.keepSeconds }
            failures = 0
            note = nil
        } else {
            failures += 1
            // ssh itself exits 255; with BatchMode that is almost always auth or reachability.
            note = spec.host != nil && exitStatus == 255 ? "ssh の認証に失敗" : nil
        }
    }

    func snapshot(now: Date) -> JobSnapshot {
        var snap = JobEstimator.evaluate(label: spec.label, samples: samples, failures: failures,
                                         now: now, stallMinutes: spec.stallMinutes)
        snap.note = note
        return snap
    }
}

/// Runs each registered job's probe on a timer in canopyd and writes the
/// result to `OpenSession.job`, which `session_state` and the roster carry.
/// No model turn is involved.
@MainActor
final class JobWatcher {
    static let shared = JobWatcher()

    static let probeTimeout: TimeInterval = 30
    /// A registration whose session has not been open for this long is dropped. Long
    /// enough that a daemon restart, which reopens sessions after this restores, keeps it.
    static let orphanSeconds: TimeInterval = 15 * 60

    /// Called when a job's state changes (not on its first reading). Task 4 posts pushes from it.
    var onTransition: ((OpenSession, JobState, JobSnapshot) -> Void)?

    private weak var store: SessionStore?
    private var tracks: [String: JobTrack] = [:]
    private var timers: [String: Timer] = [:]
    private var running: Set<String> = []
    private var lastState: [String: JobState] = [:]
    private var missingSince: [String: Date] = [:]

    private var persistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Canopy/jobs-\(Bundle.main.bundleIdentifier ?? "Canopy").json")
    }

    /// Restores saved jobs. Called once by the daemon.
    func start(store: SessionStore) {
        self.store = store
        guard let data = try? Data(contentsOf: persistURL),
              let saved = try? JSONDecoder().decode([JobTrack].self, from: data) else { return }
        for track in saved {
            tracks[track.spec.resumeId] = track
            schedule(track.spec)
        }
        logger.notice("restored \(saved.count) job(s)")
    }

    @discardableResult
    func watch(_ spec: JobSpec) -> JobSnapshot {
        tracks[spec.resumeId] = JobTrack(spec: spec)
        lastState[spec.resumeId] = nil
        missingSince[spec.resumeId] = nil
        save()
        schedule(spec)
        let snap = tracks[spec.resumeId]!.snapshot(now: Date())
        session(spec.resumeId)?.job = snap
        return snap
    }

    @discardableResult
    func clear(resumeId: String) -> Bool {
        guard tracks.removeValue(forKey: resumeId) != nil else { return false }
        timers.removeValue(forKey: resumeId)?.invalidate()
        lastState[resumeId] = nil
        missingSince[resumeId] = nil
        save()
        session(resumeId)?.job = nil
        return true
    }

    func snapshot(resumeId: String) -> JobSnapshot? {
        tracks[resumeId]?.snapshot(now: Date())
    }

    // MARK: Probe command

    static func command(for spec: JobSpec) -> [String] {
        guard let host = spec.host else { return ["/bin/sh", "-c", spec.probe] }
        let cm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/cm").path
        return ["/usr/bin/ssh",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=auto", "-o", "ControlPath=\(cm)/%r@%h:%p", "-o", "ControlPersist=10m",
                host, spec.probe]
    }

    /// The agent socket the sessions' ssh uses: Claude Code reads it from settings.json's
    /// `env`, which canopyd's own environment never sees.
    static func sshAuthSock(settingsJSON: Data?, fallback: String?) -> String? {
        let object = settingsJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let env = object?["env"] as? [String: Any]
        return (env?["SSH_AUTH_SOCK"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    // MARK: Running

    private func schedule(_ spec: JobSpec) {
        timers.removeValue(forKey: spec.resumeId)?.invalidate()
        let id = spec.resumeId
        timers[id] = Timer.scheduledTimer(withTimeInterval: max(spec.interval, 30), repeats: true) { _ in
            MainActor.assumeIsolated { JobWatcher.shared.tick(id) }
        }
        tick(id)
    }

    private func tick(_ id: String) {
        guard let track = tracks[id], !running.contains(id) else { return }
        if session(id) == nil {
            let since = missingSince[id] ?? Date()
            missingSince[id] = since
            if Date().timeIntervalSince(since) > Self.orphanSeconds { clear(resumeId: id) }
            return
        }
        missingSince[id] = nil
        running.insert(id)
        let argv = Self.command(for: track.spec)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let settings = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))
        if let sock = Self.sshAuthSock(settingsJSON: settings, fallback: env["SSH_AUTH_SOCK"]) { env["SSH_AUTH_SOCK"] = sock }
        if track.spec.host != nil {
            try? FileManager.default.createDirectory(
                at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/cm"),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        Self.run(argv, env: env, timeout: Self.probeTimeout) { output, status in
            MainActor.assumeIsolated { JobWatcher.shared.finish(id, spec: track.spec, output: output, status: status) }
        }
    }

    private func finish(_ id: String, spec: JobSpec, output: String?, status: Int32) {
        running.remove(id)
        // Re-registered or cleared while the probe ran: this reading belongs to the old job.
        guard var track = tracks[id], track.spec == spec else { return }
        track.record(output: output, exitStatus: status, at: Date())
        tracks[id] = track
        save()
        let snap = track.snapshot(now: Date())
        guard let session = session(id) else { return }
        if session.job != snap { session.job = snap }
        let previous = lastState[id]
        lastState[id] = snap.state
        if let previous, previous != snap.state { onTransition?(session, snap.state, snap) }
    }

    /// Runs off the main thread; `completion` is called on the main queue. A run past
    /// `timeout` is terminated and reported as a failure (status -1).
    nonisolated private static func run(_ argv: [String], env: [String: String], timeout: TimeInterval,
                                        completion: @escaping @Sendable (String?, Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.environment = env
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(nil, -1) }
                return
            }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            let timedOut = process.terminationReason == .uncaughtSignal
            let output = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
            let status = timedOut ? -1 : process.terminationStatus
            DispatchQueue.main.async { completion(output, status) }
        }
    }

    private func session(_ resumeId: String) -> OpenSession? {
        store?.openSessions.first { $0.resumeId == resumeId }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(tracks.values))
            try data.write(to: persistURL, options: .atomic)
        } catch {
            logger.error("saving jobs failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
