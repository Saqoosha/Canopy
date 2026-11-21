import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "JobWatcher")

/// A job as `canopyctl job watch` registers it. Keyed by the session's `resumeId`,
/// which survives a daemon restart.
struct JobSpec: Codable, Equatable {
    static let labelLimit = 60

    let resumeId: String
    let label: String
    /// Prints `N/M`, or with `total`, a count.
    let probe: String
    /// Run the probe over ssh on this host; nil runs it here.
    let host: String?
    let total: Int?
    let interval: TimeInterval
    let stallMinutes: Double?

    /// A host name or `user@host`: never an ssh option (`-oProxyCommand=…`) or several words.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.contains { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }
    }
}

/// One job's readings. Pure, so the probe can drive it with made-up output.
struct JobTrack: Codable, Equatable {
    /// Unchanged readings older than this are dropped; the reading where the count last
    /// changed is always kept, so a long stall keeps its start.
    static let keepSeconds: TimeInterval = 4 * 3600
    static let sampleLimit = 2000
    /// Between runs of a job whose probe keeps failing. Each ssh retry can raise a
    /// 1Password approval nobody sees, and the 1Password prompt watcher pages for every one.
    static let unknownRetrySeconds: TimeInterval = 15 * 60

    var spec: JobSpec
    var samples: [JobSample] = []
    var failures = 0
    var note: String?
    /// When the probe last ran, so an `unknown` job can back off.
    var lastRun: Date?
    /// The state the last reading produced: a failed reading keeps a stall, and pushes
    /// fire on a change from it, across daemon restarts too.
    var lastState: JobState?

    init(spec: JobSpec) { self.spec = spec }

    /// False while an `unknown` job is inside its backoff.
    func shouldRun(now: Date) -> Bool {
        guard failures >= JobEstimator.failureLimit, let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= Self.unknownRetrySeconds
    }

    /// Folds one probe run in. Output without a count is a failure, never `done = 0`.
    mutating func record(output: String?, exitStatus: Int32, at now: Date) {
        lastRun = now
        if exitStatus == 0, let output, let count = JobEstimator.parse(output, total: spec.total) {
            samples.append(JobSample(at: now, done: count.done, total: count.total))
            prune(now: now)
            failures = 0
            note = nil
        } else {
            failures += 1
            note = Self.failureNote(output: output, exitStatus: exitStatus, overSSH: spec.host != nil)
        }
    }

    func snapshot(now: Date) -> JobSnapshot {
        var snap = JobEstimator.evaluate(label: spec.label, samples: samples, failures: failures,
                                         now: now, stallMinutes: spec.stallMinutes, previous: lastState)
        snap.note = note
        snap.lastReadingAt = samples.last?.at
        return snap
    }

    private mutating func prune(now: Date) {
        var kept: [JobSample] = []
        for (i, sample) in samples.enumerated() {
            let changed = i == 0 || samples[i - 1].done != sample.done || samples[i - 1].total != sample.total
            if changed || now.timeIntervalSince(sample.at) <= Self.keepSeconds { kept.append(sample) }
        }
        samples = Array(kept.suffix(Self.sampleLimit))
    }

    /// Why a reading is missing, for the hover and `job list`: the cause, then the probe's last
    /// stdout line (stderr is not kept; see `runSync`).
    static func failureNote(output: String?, exitStatus: Int32, overSSH: Bool) -> String {
        let line = output?.split(whereSeparator: \.isNewline).last.map { String($0.prefix(80)) }
        switch exitStatus {
        case JobWatcher.timedOut:
            return overSSH ? "ssh が応答しない（1Password の承認待ちかも）" : "30 秒で終わらない"
        case JobWatcher.launchFailed: return "起動できない"
        case JobWatcher.tooMuchOutput: return "出力が多すぎる"
        case 0: return overSSH || line != nil ? "出力に数が無い" : "出力が空"
        case 255 where overSSH: return "ssh の接続か認証に失敗" + (line.map { ": \($0)" } ?? "")
        default: return "exit \(exitStatus)" + (line.map { ": \($0)" } ?? "")
        }
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

    private weak var store: SessionStore?
    private var tracks: [String: JobTrack] = [:]
    private var timers: [String: Timer] = [:]
    private var running: Set<String> = []
    private var missingSince: [String: Date] = [:]
    /// Bumped by every registration and never reset, so a probe started for an earlier
    /// registration of the same spec cannot land in the new one.
    private var generations: [String: Int] = [:]

    private var persistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Canopy/jobs-\(Bundle.main.bundleIdentifier ?? "Canopy").json")
    }

    /// Restores saved jobs. Called once by the daemon. A file that cannot be read is moved aside
    /// and logged rather than silently replaced by the next save.
    func start(store: SessionStore) {
        self.store = store
        guard FileManager.default.fileExists(atPath: persistURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode([JobTrack].self, from: Data(contentsOf: persistURL))
            for track in saved {
                tracks[track.spec.resumeId] = track
                schedule(track.spec)
            }
            logger.notice("restored \(saved.count) job(s)")
        } catch {
            let aside = persistURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: persistURL, to: aside)
            logger.error("jobs file unreadable, moved to \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func watch(_ spec: JobSpec) -> JobSnapshot {
        tracks[spec.resumeId] = JobTrack(spec: spec)
        generations[spec.resumeId, default: 0] += 1
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
        // pipefail: `ls missing | wc -l` prints 0 and would otherwise read as a count.
        guard let host = spec.host else { return ["/bin/sh", "-c", "set -o pipefail; " + spec.probe] }
        let cm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/cm").path
        return ["/usr/bin/ssh",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=auto", "-o", "ControlPath=\(cm)/%r@%h:%p", "-o", "ControlPersist=10m",
                "--", host, spec.probe]
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
        // A closed session's job goes first, finished or backing off included.
        if session(id) == nil {
            let since = missingSince[id] ?? Date()
            missingSince[id] = since
            if Date().timeIntervalSince(since) > Self.orphanSeconds { clear(resumeId: id) }
            return
        }
        missingSince[id] = nil
        // A session reopened after a daemon restart has no job until its next reading; the
        // reaper's hold needs it now.
        if let session = session(id), session.job == nil { session.job = track.snapshot(now: Date()) }
        // A finished count will not move again: keep the job for the row, stop asking.
        guard track.lastState != .done, track.shouldRun(now: Date()) else { return }
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
        let generation = generations[id, default: 0]
        Self.run(argv, env: env, timeout: Self.probeTimeout) { output, status in
            MainActor.assumeIsolated { JobWatcher.shared.finish(id, generation: generation, output: output, status: status) }
        }
    }

    private func finish(_ id: String, generation: Int, output: String?, status: Int32) {
        running.remove(id)
        guard var track = tracks[id] else { return }
        // Re-registered while this probe ran: the reading is the old job's; read the new one now.
        guard generations[id, default: 0] == generation else { tick(id); return }
        let previous = track.lastState
        track.record(output: output, exitStatus: status, at: Date())
        let snap = track.snapshot(now: Date())
        track.lastState = snap.state
        tracks[id] = track
        save()
        guard let session = session(id) else { return }
        if session.job != snap { session.job = snap }
        if Self.shouldPush(from: previous, to: snap.state), let text = Self.pushText(snap) {
            RosterNotifier.post(kind: snap.state == .done ? .jobDone : .jobStalled,
                                sessionId: session.id.uuidString, resumeId: session.resumeId,
                                title: text.title, body: text.body, answerable: false,
                                sessionTitle: session.title)
        }
    }

    /// A stall, or a probe that keeps failing, holds its session this long; past it the job is
    /// taken as dead.
    nonisolated static let stalledHoldSeconds: TimeInterval = 6 * 3600

    /// Whether a session's job keeps the daemon from reaping it: one that is measuring or
    /// running, stalled for under `stalledHoldSeconds`, or `unknown` with a good reading in that
    /// time (a short outage, such as an unseen 1Password prompt, must not drop the job). Never `done`.
    nonisolated static func holdsSession(_ job: JobSnapshot?, now: Date = Date()) -> Bool {
        guard let job else { return false }
        switch job.state {
        case .measuring, .running: return true
        case .stalled: return job.stalledSince.map { now.timeIntervalSince($0) < stalledHoldSeconds } ?? true
        case .unknown: return job.lastReadingAt.map { now.timeIntervalSince($0) < stalledHoldSeconds } ?? false
        case .done: return false
        }
    }

    /// One push when a job moves into `stalled` or `done`; none on its first reading,
    /// so a re-registered job does not repeat an old push.
    static func shouldPush(from previous: JobState?, to next: JobState) -> Bool {
        guard let previous, previous != next else { return false }
        return next == .stalled || next == .done
    }

    static func pushText(_ job: JobSnapshot) -> (title: String, body: String)? {
        switch job.state {
        case .stalled: return (job.label, "\(job.done)/\(job.total) で止まっている")
        case .done: return (job.label, "完了")
        case .measuring, .running, .unknown: return nil
        }
    }

    /// Runs off the main thread; `completion` is called on the main queue.
    nonisolated private static func run(_ argv: [String], env: [String: String], timeout: TimeInterval,
                                        completion: @escaping @Sendable (String?, Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runSync(argv, env: env, timeout: timeout)
            DispatchQueue.main.async { completion(result.output, result.status) }
        }
    }

    /// Statuses `runSync` returns in place of an exit code.
    nonisolated static let timedOut: Int32 = -1
    nonisolated static let launchFailed: Int32 = -2
    nonisolated static let tooMuchOutput: Int32 = -3
    nonisolated static let outputLimit = 1 << 20

    /// Runs `argv` and waits for its stdout pipe to close and then for it to exit, both within
    /// one `timeout`. The pipe can close first (`exec >/dev/null; sleep 600`) or last (a child
    /// left behind holds it after `sh` exits). Past the timeout or `outputLimit`, the process
    /// tree is killed and the read abandoned.
    nonisolated static func runSync(_ argv: [String], env: [String: String], timeout: TimeInterval)
        -> (output: String?, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        // Not merged into the pipe: a warning after the count would be read as the count.
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch {
            logger.error("probe did not start: \(error.localizedDescription, privacy: .public)")
            return (nil, launchFailed)
        }
        let pid = process.processIdentifier
        // Read now: once sh has exited and been reaped, getpgid fails, yet its group lives on in
        // the children it left behind.
        let group = getpgid(pid)
        let buffer = OSAllocatedUnfairLock(initialState: (data: Data(), overflow: false))
        let closed = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            let stop = buffer.withLock { state -> Bool in
                if chunk.isEmpty { return true }
                state.data.append(chunk)
                if state.data.count > outputLimit { state.overflow = true; return true }
                return false
            }
            if stop { handle.readabilityHandler = nil; closed.signal() }
        }
        let pipeClosed = closed.wait(timeout: deadline) == .success
        let overflow = buffer.withLock { $0.overflow }
        let finished = pipeClosed && (overflow || exited.wait(timeout: deadline) == .success)
        if !finished || overflow {
            reader.readabilityHandler = nil
            killTree(pid, group: group == pid ? group : nil)
            // A process stuck in the kernel (a hung network mount) outlives SIGKILL: give up on it.
            if exited.wait(timeout: .now() + 5) == .timedOut {
                logger.error("probe pid \(pid) did not exit after SIGKILL")
                try? reader.close()
                return (buffer.withLock { String(decoding: $0.data.suffix(64 * 1024), as: UTF8.self) },
                        overflow ? tooMuchOutput : timedOut)
            }
        }
        process.waitUntilExit()
        let output = buffer.withLock { String(decoding: $0.data.suffix(64 * 1024), as: UTF8.self) }
        if overflow { return (output, tooMuchOutput) }
        if !finished { return (output, timedOut) }
        return (output, process.terminationStatus)
    }

    /// Kills `pid`'s descendants (found by parent pid, never by name), then `pid`, then `group`
    /// when the probe led its own, which also reaches children `sh` left behind. Never canopyd's.
    nonisolated private static func killTree(_ pid: pid_t, group: pid_t?) {
        var queue = [pid], all: [pid_t] = []
        while let next = queue.popLast() {
            all.append(next)
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", String(next)]
            let out = Pipe()
            pgrep.standardOutput = out
            pgrep.standardError = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { continue }
            pgrep.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            queue += text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        }
        for victim in all.reversed() { kill(victim, SIGKILL) }
        if let group { killpg(group, SIGKILL) }
    }

    private func session(_ resumeId: String) -> OpenSession? {
        store?.openSessions.first { $0.resumeId == resumeId }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(tracks.values))
            try data.write(to: persistURL, options: .atomic)
            // Probes are commands canopyd runs: no other process should read or edit them.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistURL.path)
        } catch {
            logger.error("saving jobs failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
