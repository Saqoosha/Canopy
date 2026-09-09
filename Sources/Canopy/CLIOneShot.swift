import Foundation
import os

/// Runs the Claude CLI once, outside any session, and hands back its stdout.
///
/// Extracted from `SessionTitleGenerator`, which was the only caller until
/// `WorktreeBranchNamer` needed the same thing. What is shared is the process
/// mechanics, and every one of them is a hazard that was found the hard way:
/// an unbounded drain that must not deadlock, a watchdog that must escalate to
/// SIGKILL, a completion that must fire exactly once even when the child never
/// releases its output, and a stdin that must be written and closed or the CLI
/// waits on it. Duplicating that per caller means duplicating five ways to
/// hang a worker with no log.
///
/// What is deliberately NOT shared is anything about *meaning*: the system
/// prompt, how the payload is framed, and what counts as a usable answer stay
/// with each caller, because those are what the two uses disagree about.
enum CLIOneShot {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CLIOneShot")

    /// A latch settable once and readable from another queue. Used twice below
    /// — "the watchdog killed this" and "the child has been reaped" — so it is
    /// named for the shape, not for either use. Same implementation as
    /// `GitWorktree`'s.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Calls its body at most once, whoever gets there first.
    ///
    /// Two callers race for it by design: the normal path, and the deadline
    /// that answers regardless (see `finishSlack`). A late real result is
    /// dropped rather than delivered after the caller has moved on.
    private final class OnceFinish: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let body: @Sendable (String?) -> Void
        init(_ body: @escaping @Sendable (String?) -> Void) { self.body = body }
        /// Returns whether this call was the one that answered. The deadline
        /// logs only when it wins: consulting a separate `hasFinished` first is
        /// check-then-act, and the normal path latching in between made the log
        /// claim a healthy run had been abandoned.
        @discardableResult
        func callAsFunction(_ value: String?) -> Bool {
            lock.lock()
            if done { lock.unlock(); return false }
            done = true
            lock.unlock()
            body(value)
            return true
        }
    }

    /// Grace period between the watchdog's SIGTERM and a SIGKILL.
    ///
    /// Not optional politeness. `waitUntilExit()` returns only once the child
    /// is reaped, and the reads above it return only at EOF — so a CLI that
    /// catches SIGTERM and hangs in shutdown blocks worker threads for as long
    /// as it lasts. `RemoteSessionsBridge` and `killTree` both escalate for the
    /// same reason. The residual case a SIGKILL cannot close is a grandchild
    /// inheriting the stdout write end; that is accepted, not solved.
    ///
    /// The caller is not at stake here — `finishSlack` answers it on a
    /// schedule regardless. This escalation is about the threads.
    static let killGrace: TimeInterval = 3

    /// Extra time past `timeout + killGrace` before the caller is answered
    /// regardless of what the subprocess is doing.
    ///
    /// This exists because the watchdog bounds the CHILD, not the operation.
    /// `group.wait()` and `waitUntilExit()` are both unbounded, and the `finish`
    /// calls that report a result all sit downstream of them (the launch-failure
    /// branch answers earlier). So a grandchild that inherited the stdout write
    /// end keeps the drain from ever seeing EOF, and no signal to the direct
    /// child can change that. Without a scheduled answer, a caller that latches
    /// an "in flight" flag keeps it set for the life of the session, silently
    /// disabling its own feature — and nothing logs it.
    ///
    /// What this does NOT do is unblock the wedge: THREE global-queue threads
    /// stay parked (both drains in `availableData`, plus the worker in
    /// `group.wait()`), along with a `Process`, three `Pipe`s and their
    /// descriptors. Callers bound how often that can happen — titling by
    /// `maxGenerations` per launch, branch naming by being once per worktree.
    /// That leak is the lesser evil: a wedged reader costs threads, a wedged
    /// state machine costs the feature.
    static let finishSlack: TimeInterval = 5

    /// Read a handle to EOF, keeping at most `outputCap` bytes.
    ///
    /// It keeps reading past the cap rather than returning early: stopping
    /// would leave the child blocked on a full pipe and `waitUntilExit()`
    /// hanging on a child that never exits. Callers use only the first line, so
    /// the discard costs nothing.
    private static let outputCap = 64 * 1024

    private static func drain(_ handle: FileHandle) -> Data {
        var collected = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count < outputCap {
                collected.append(chunk.prefix(outputCap - collected.count))
            }
        }
        return collected
    }

    /// Run the CLI once. `completion` is called exactly once, on the main
    /// actor, with raw stdout or nil — every early exit answers, and a
    /// scheduled deadline answers for the paths that cannot.
    ///
    /// `label` is only for logging, and it is not optional in practice: Canopy
    /// runs up to six panes and `process == "Canopy"` already mixes the Debug
    /// and Release builds, so a bare "exited 1" names none of the sessions it
    /// could belong to. `logPrefix` keeps each caller's lines greppable as a
    /// set (`[title]`, `[branch]`).
    ///
    /// The payload is piped to the child's stdin rather than passed on argv —
    /// see `SessionTitleGenerator.arguments` for why that is a requirement and
    /// not a preference. Piping also settles the latency question an earlier
    /// `/dev/null` stdin was there for: an *inherited* stdin makes the CLI wait
    /// three seconds for input that never comes, and a pipe that is written and
    /// closed gives it the input immediately.
    ///
    /// Returning nil is a real outcome rather than a failure to handle. What to
    /// do about "this produced nothing" belongs to the caller, which is why no
    /// fallback is applied here.
    static func run(
        cli: URL,
        arguments: [String],
        environment: [String: String],
        stdinPayload: Data,
        label: String,
        logPrefix: String,
        timeout: TimeInterval,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let finish = OnceFinish { result in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
        let workDir = FileManager.default.temporaryDirectory

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = environment
            // Explicit, because an `open`-launched GUI app's cwd is `/`. The
            // CLI records its transcript against the cwd either way; naming one
            // makes where that lands predictable instead of incidental.
            process.currentDirectoryURL = workDir

            // Answer the caller on a schedule, independent of the reads below.
            // See `finishSlack` — this is what keeps a wedged pipe from
            // disabling the feature for the rest of the session.
            let queue = DispatchQueue.global(qos: .utility)
            let abandon = DispatchWorkItem {
                if finish(nil) {
                    logger.notice("\(logPrefix, privacy: .public) \(label, privacy: .public): abandoned, subprocess never released its output")
                }
            }

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                logger.notice("\(logPrefix, privacy: .public) \(label, privacy: .public): launch failed: \(error.localizedDescription, privacy: .public)")
                finish(nil)
                return
            }

            // Armed BEFORE the write, not after it. The write does not block on
            // any realistic payload — callers cap what they send well under the
            // 16KB floor of a macOS pipe buffer — but "does not" is not
            // "cannot": `prefix` counts Characters, and a Character is an
            // arbitrary grapheme cluster, so a payload of family-emoji
            // sequences would be several times its character count in bytes and
            // would block. Arming first is what keeps that case, or a future
            // wider window, from hanging a worker with no watchdog and no log.
            let timedOut = OnceFlag()
            let reaped = OnceFlag()
            let watchdog = DispatchWorkItem { [weak process] in
                guard let process, !reaped.value, process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            // Escalation, not decoration — see `killGrace`. `reaped` NARROWS the
            // check-then-act window rather than closing it: it is set after
            // `waitUntilExit()` returns, i.e. after the reap, so a killer that
            // read both flags just before that can still signal afterwards. The
            // residual window is a few instructions instead of seconds, and the
            // watchdog's `terminate()` above has the same exposure.
            let killer = DispatchWorkItem { [weak process] in
                guard let process, !reaped.value, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            queue.asyncAfter(deadline: .now() + timeout + killGrace, execute: killer)
            // Same clock as the watchdog, deliberately. Scheduled before
            // `run()` it would lose however long the spawn took out of its own
            // margin — and spawning a ~250MB signed binary on a cold cache is
            // the one step here that can plausibly cost seconds, which would
            // let the deadline answer over a healthy run.
            queue.asyncAfter(deadline: .now() + timeout + killGrace + finishSlack, execute: abandon)

            // Closed so the CLI sees EOF and stops waiting for more. Failures
            // are logged rather than swallowed: a short write leaves the child
            // working on half a payload and exiting 0, which is
            // indistinguishable from a good answer, and a failed close leaves it
            // waiting on stdin until the watchdog kills it — reported as a
            // timeout with no hint of the real cause.
            do {
                try stdin.fileHandleForWriting.write(contentsOf: stdinPayload)
            } catch {
                logger.notice("\(logPrefix, privacy: .public) \(label, privacy: .public): stdin write failed: \(error.localizedDescription, privacy: .public)")
            }
            // Closed unconditionally, outside the `do`. Leaving it open on a
            // failed write turns that failure into a full-timeout stall with the
            // real cause nowhere in the log — the exact misdiagnosis the comment
            // above says it wants to avoid.
            try? stdin.fileHandleForWriting.close()

            // Both streams are drained concurrently. Reading them in sequence
            // deadlocks the moment the one not being read fills its 64KB pipe
            // buffer — the child blocks writing, so the stream being read never
            // reaches EOF. Same reason `CloneRepoSheet` uses a group.
            let group = DispatchGroup()
            var outData = Data()
            var errData = Data()
            queue.async(group: group) { outData = drain(stdout.fileHandleForReading) }
            queue.async(group: group) { errData = drain(stderr.fileHandleForReading) }
            group.wait()

            process.waitUntilExit()
            reaped.set()
            watchdog.cancel()
            killer.cancel()
            // Cancelled too, or every run leaves a work item queued for the
            // full deadline holding the completion closure alive.
            abandon.cancel()

            // Never `String(data:encoding:)` on either stream: `drain` cuts at
            // a byte boundary, so a split multi-byte sequence would make the
            // WHOLE buffer decode to nil — discarding a good answer on line 1
            // and printing an empty diagnostic.
            let errText = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errTail = errText.isEmpty ? "no stderr" : String(errText.prefix(300))

            if timedOut.value {
                logger.notice("\(logPrefix, privacy: .public) \(label, privacy: .public): timed out after \(Int(timeout), privacy: .public)s: \(errTail, privacy: .public)")
                finish(nil)
                return
            }
            guard process.terminationStatus == 0 else {
                // stderr carries the only usable diagnosis the CLI produces —
                // an expired login, a flag this CLI version does not know
                // (which would make a `--setting-sources ''` style fix fail
                // closed), a provider 401, a network error. Discarding it left
                // every one of those looking like "exited 1".
                logger.notice("\(logPrefix, privacy: .public) \(label, privacy: .public): exited \(process.terminationStatus, privacy: .public): \(errTail, privacy: .public)")
                finish(nil)
                return
            }
            finish(String(decoding: outData, as: UTF8.self))
        }
    }
}
