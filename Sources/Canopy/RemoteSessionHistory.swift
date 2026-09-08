import Foundation
import os

/// Session discovery for SSH remote sessions.
///
/// `ClaudeSessionHistory` reads `~/.claude/projects` on THIS machine. A remote
/// session's CLI runs on the other machine and writes its transcript there, so
/// every local lookup misses and the launcher's "Continue session" could never
/// find anything to resume — a remote launch always started a fresh
/// conversation, however many times the same directory had been used.
///
/// Worse than a plain miss when the same path exists on both machines
/// (`/Users/hiko/repos/…` commonly does): the local folder resolves, so the id
/// reaches `data-initial-session` and the extension replays a LOCAL
/// conversation into the pane while the remote CLI runs with none. Not "the
/// remote CLI starts fresh under a foreign id", which an earlier version of
/// this paragraph said — nothing reached the remote CLI at all, and handing it
/// an unresolvable id is an exit 1 rather than a fresh start.
///
/// "Silently" was this file's own word for that and it is not accurate: the
/// extension emits `{"type":"system","subtype":"status","resumeDropped":true,
/// "sessionId":…}` on the wire when it cannot resolve a session (measured in
/// `extension.js` 2.1.263). Canopy does not surface or read that frame, which
/// is what makes the outcome silent to the USER. It reports THAT a resume was
/// dropped, never which session to continue, so it cannot replace this lookup —
/// but it would let Canopy tell the user, which nothing does today.
///
/// **What the probe does and does not pin.** Every pure surface here is
/// covered — `classify`'s filter ladder, `escalationSkip`/`absoluteStop`,
/// `resolvedPath`, `isSpawnableHost`, `remoteScript`'s interpolations. None of
/// the WIRING is: `run`, `runOnce` and `scan` need a live ssh, so a reviewer
/// measured that deleting the `isSpawnableHost` guard, hardcoding `run`'s
/// `skipping:` to 0, dropping the `SessionTitleStore` override, or collapsing
/// `absoluteStop` all leave the suite green. Read an assertion here as pinning
/// the function it names and nothing above it. Closing the gap needs `scan`'s
/// read loop lifted into a pure chunk consumer, which is recorded as follow-up
/// rather than done, because adding more scaffolding is how a review loop
/// starts reviewing itself.
///
/// This type closes that by listing the remote store over SSH. It answers only
/// the one question the launcher asks — *which session would "continue" resume*
/// — and deliberately does not build a remote session list; see the header
/// streaming note on `latestSession`.
enum RemoteSessionHistory {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteSessionHistory")

    /// How many transcripts the remote is asked to walk, newest first.
    ///
    /// Generous because the interesting ones are sparse: automated runs
    /// (sub-agents, `/security-review`, title generation) each write a JSONL
    /// and are dropped on sight. A cap of a handful would routinely see nothing
    /// but automated runs and report "no session to continue" on a directory
    /// with plenty.
    ///
    /// It is affordable only because of the streaming below: the remote emits
    /// headers one at a time and the read stops at the first survivor, so the
    /// cost is roughly the headers up to the answer rather than all of this
    /// number — "roughly" because closing the pipe only stops the remote's
    /// NEXT `printf`.
    ///
    /// How many that is depends on the folder, and the honest worst case is the
    /// whole window — `maxCandidates` × the fetched header, base64-inflated.
    /// A folder holding nothing but automated runs pays it in full and returns
    /// nil, and every transcript written before `CLAUDE_CODE_ENTRYPOINT` was
    /// forwarded is stamped `sdk-cli`, so that is the transition case rather
    /// than a pathological one. Concretely: ~10.5 MB at the first window,
    /// ~168 MB at the escalated one if the skip below buys nothing.
    ///
    /// The survival ratio this rests on is measured once, on
    /// `ClaudeSessionHistory.maxSessionsToKeep`. Not restated here — it is
    /// dated, it drifts as the machine is used, and a copy without its date
    /// and population is a copy that will quietly disagree.
    static let maxCandidates = 60

    /// Overall budget for one SSH round trip, so the launch cannot sit behind a
    /// spinner with nothing to cancel it.
    ///
    /// NOT the passphrase case — an earlier version of this comment said so and
    /// was wrong: `BatchMode=yes` below makes ssh fail rather than prompt. What
    /// it covers is a connection that neither completes nor drops, which
    /// `ConnectTimeout` does not bound because that only governs the TCP
    /// connect: a host that has gone away mid-keepalive, or a transfer that
    /// stalls part way through a large header.
    ///
    /// `latestSession` can spend this twice (the resolved-path retry), and each
    /// pass can itself escalate, so the wall-clock ceiling is a multiple of it.
    private static let timeout: TimeInterval = 20

    /// The newest session under `directory` on `host` that a user would
    /// recognise as theirs — automated and scheduled-task transcripts skipped,
    /// by the same `HeaderScanner` the local loader runs.
    ///
    /// **The remote streams headers and the read stops at the first survivor.**
    /// One SSH connection PER PASS, and the remote stops producing headers
    /// shortly past the answer — whatever was already buffered when the read
    /// end closed was sent. Passes are not always one: a symlinked directory costs a
    /// second, and either can escalate its window, so the ceiling here is four
    /// — see `run` and `timeout`.
    /// That is what makes `maxCandidates` cheap, and it is also why this
    /// returns one entry rather than a list: a list would have to drain the
    /// whole window, which is the expensive shape this avoids.
    ///
    /// Returns nil when the host is unreachable or refused as option-shaped, the
    /// project folder does not exist there, or every candidate was filtered out.
    /// All of them land on the launcher's existing "no session to continue"
    /// behaviour — a fresh session, which is what it did before this existed —
    /// so the log is the only thing that separates them; see `scan`.
    static func latestSession(host: String, directory: URL) async -> SessionEntry? {
        // The host is a free-text field. `ssh` takes it as a positional
        // argument, and a value beginning with `-` is read as an option
        // instead — `-oProxyCommand=…` being the interesting one. Nothing here
        // goes through a shell, so this is the whole of the exposure, and
        // refusing the leading dash closes it without guessing at what a valid
        // hostname looks like.
        guard isSpawnableHost(host) else {
            logger.error("refusing an ssh host that would be read as an option")
            return nil
        }

        let first = await run(host: host, directory: directory, path: directory.path)
        if let entry = first.entry { return entry }

        // The CLI stores a transcript under the encoding of the path it
        // RESOLVED, not the one it was given, so a symlinked working directory
        // is filed somewhere the requested path's encoding never names.
        // Measured on the host this was built against: `/tmp` resolves to
        // `/private/tmp`, and a session started there lands in
        // `-private-tmp` while the lookup for `/tmp` asks for `-tmp` — one
        // `ls` over a glob that matches nothing, ssh exits 0, and the launcher
        // silently opens a fresh session. `~/Documents/repos` → `~/repos` is
        // the same shape on a path people actually work in.
        //
        // Deliberately a SECOND round trip rather than resolving up front:
        // resolution is a remote question (the link is on the other machine),
        // and the overwhelmingly common case is a path that resolves to
        // itself, which would then pay for a round trip that changes nothing.
        guard let resolved = first.resolvedPath,
              resolved != directory.path
        else { return nil }

        logger.notice("retrying remote lookup at the resolved path on \(host, privacy: .public)")
        return await run(host: host, directory: directory, path: resolved).entry
    }

    /// One SSH round trip against `path`'s encoded project folders, reporting
    /// what the remote resolved `path` to so the caller can decide whether a
    /// second pass is worth it. `directory` is what the user picked and is only
    /// carried into the returned entry — never encoded.
    private static func run(
        host: String, directory: URL, path: String
    ) async -> (entry: SessionEntry?, resolvedPath: String?) {
        let first = await runOnce(
            host: host, directory: directory, path: path,
            window: ClaudeSessionHistory.metadataHeadSize
        )
        guard first.needsEscalation else { return (first.entry, first.resolvedPath) }

        // A candidate whose header did not fit is NOT a candidate we may skip
        // past: the record that names it automated is the one that got cut, so
        // "nothing disqualifying seen" and "we never reached the header" look
        // identical. `extractMetadata` faces the same thing locally and answers
        // it by reading further, up to `metadataMaxScanSize`; this is that rule,
        // one machine over. How often it is needed is measured once, on
        // `metadataMaxScanSize` itself. The shape that needs it is exactly the
        // one being filtered — a
        // `/security-review` whose opening `queue-operation` carries the whole
        // diff, pushing its `type: "user"` record past the head chunk.
        //
        // The listing COMMAND is re-run rather than a single file fetched,
        // because which candidate wins depends on the ones before it:
        // escalating only the ambiguous file would still leave the scan
        // deciding on candidates it read at the smaller window.
        //
        // What it does NOT re-read is the candidates already decided. Start at
        // the one that could not be classified, not at the top.
        //
        // A `.malformed` candidate is skipped past too, and one route into
        // that case — a window that ended before any record completed — could
        // have parsed at the wider one. Every other route is a property of the
        // bytes rather than of the window and cannot change. See the residual
        // recorded on `classify`; that miss is the accepted cost.
        //
        // Everything else before it was `.filtered` on an `sdk-*` entrypoint or
        // a scheduled-task record, and neither verdict can change by reading
        // FURTHER into the same file — so re-fetching them at the wide window
        // buys nothing and costs 16x per candidate. A reviewer put the
        // unskipped worst case at ~168 MB inside the same 20 s deadline,
        // against ~10.5 MB for the first pass; skipping makes the common case
        // exactly one wide header.
        logger.notice(
            "escalating remote header window on \(host, privacy: .public) from candidate \(first.escalateFrom)"
        )
        let escalated = await runOnce(
            host: host, directory: directory, path: path,
            window: ClaudeSessionHistory.metadataMaxScanSize,
            skipping: escalationSkip(stoppedAt: first.escalateFrom)
        )
        return (escalated.entry, escalated.resolvedPath ?? first.resolvedPath)
    }

    /// How many candidates the escalated pass may skip, given where the first
    /// pass stopped.
    ///
    /// Pure so the arithmetic can be pinned at all: `run` needs a live ssh.
    ///
    /// Read that narrowly. The probe fails if this FUNCTION returns something
    /// else; it stays green if `run` stops calling it and passes 0 — measured,
    /// by mutation, after an earlier version of this comment claimed the
    /// opposite. Extracting a decision makes the decision testable and does
    /// nothing for the wire that carries it, which is this repo's recorded
    /// "extraction pins the layer below" trap, hit here a second time.
    ///
    /// One consequence of the units: the skip counts `ls` lines while the
    /// scan counts EMITTED headers, and the remote script drops `agent-*`
    /// files between the two. A sidechain file ahead of the ambiguous
    /// candidate therefore makes the skip short, so the escalated pass
    /// re-reads some candidates it had already classified. Cost only — the
    /// skip can undershoot but never overshoot, so no candidate is skipped
    /// unclassified.
    static func escalationSkip(stoppedAt: Int) -> Int {
        max(0, stoppedAt - 1)
    }

    /// A pass's stopping position expressed in the FULL listing, given how many
    /// candidates that pass itself skipped.
    static func absoluteStop(skipping: Int, stoppedAt: Int) -> Int {
        skipping + stoppedAt
    }

    /// One SSH round trip at a fixed header window. `run` above makes one or
    /// two of these; `latestSession` bounds the whole lookup at four.
    private static func runOnce(
        host: String, directory: URL, path: String, window: Int, skipping: Int = 0
    ) async -> (entry: SessionEntry?, resolvedPath: String?, needsEscalation: Bool, escalateFrom: Int) {
        let candidates = ClaudeSessionHistory.encodedFolderCandidates(for: path)
        guard !candidates.isEmpty else { return (nil, nil, false, 0) }

        let script = remoteScript(
            path: path, encodedFolders: candidates, window: window, skipping: skipping)
        // The remote login shell is whatever the user set — fish on the host
        // this was built against, which does not parse the loop below. Ship the
        // script base64-encoded and hand it to `/bin/sh`: the payload is
        // `[A-Za-z0-9+/=]` only, so no shell on either side can find anything
        // in it to interpret.
        let encoded = Data(script.utf8).base64EncodedString()

        // At the widest window there is nothing further to read, so a header
        // that still does not fit is accepted on whatever it parsed — which is
        // what `extractMetadata` does when it hits the same ceiling.
        let isFinalWindow = window >= ClaudeSessionHistory.metadataMaxScanSize

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = scan(
                    host: host, directory: directory,
                    encodedScript: encoded, acceptExhaustedHeaders: isFinalWindow
                )
                // Report the ambiguous candidate's position in the FULL
                // listing, so a caller that already skipped some can hand the
                // next pass an absolute offset.
                continuation.resume(returning: (
                    r.entry, r.resolvedPath, r.needsEscalation,
                    absoluteStop(skipping: skipping, stoppedAt: r.stoppedAt)
                ))
            }
        }
    }

    // MARK: - Remote script

    /// Non-private so the logic probe can pin it: this string is the only
    /// thing standing between a launcher click and a shell on another machine,
    /// and none of it is exercised by any other test.
    static func remoteScript(
        path: String, encodedFolders: [String], window: Int, skipping: Int = 0
    ) -> String {
        // `ls -1t` sorts ALL of its arguments together, so listing both
        // encoding variants in one invocation orders them by mtime across the
        // two folders — which is what the local loader does by sorting merged
        // entries. Doing it per-folder would let an older strict-encoded
        // session beat a newer legacy-encoded one.
        let globs = encodedFolders
            .map { "\"$HOME/.claude/projects/\(shellEscapeForDoubleQuotes($0))\"/*.jsonl" }
            .joined(separator: " ")

        // The resolved path leads, so the caller has it even when the listing
        // that follows matches nothing — which is exactly the case it is for.
        // Emitted unconditionally, and empty when the directory is gone, so a
        // missing line is a protocol failure rather than an ordinary outcome.
        return """
        printf 'P %s\\n' "`cd \(singleQuoted(path)) 2>/dev/null && pwd -P`"
        ls -1t \(globs) 2>/dev/null | head -\(maxCandidates) | tail -n +\(skipping + 1) | while IFS= read -r f; do
          b=`basename "$f"`
          id=${b%.jsonl}
          case "$id" in agent-*) continue ;; esac
          printf '%s %s ' "$id" "`date -r "$f" +%s 2>/dev/null || echo 0`"
          head -c \(window) "$f" | base64 | tr -d '\\n'
          printf '\\n'
        done
        """
    }

    /// False for a host `ssh` would read as an option rather than a
    /// destination. Deliberately not a hostname validator: `user@host`,
    /// IPv6 literals and `~/.ssh/config` aliases are all legal here, and a
    /// pattern tight enough to be worth having would reject some of them.
    static func isSpawnableHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-")
    }

    /// A single-quoted shell literal. Unlike the encoded folder names, this
    /// wraps a path the user typed or browsed to, so nothing about its
    /// contents is guaranteed.
    private static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Neutralise the characters that survive inside a double-quoted shell
    /// string.
    ///
    /// Encoded folder names carry no shell metacharacter, but they are NOT
    /// `[A-Za-z0-9_-]` as this said before: `ClaudeSessionHistory.encodePath`
    /// keeps anything Swift calls a letter or a number, so non-ASCII survives
    /// it (`-Users-hiko-repos-Work-s支払いチェック` exists on this machine),
    /// and the legacy encoding additionally keeps `.` and spaces. The escape
    /// costs nothing and stops the guarantee resting on a second file's
    /// implementation details.
    private static func shellEscapeForDoubleQuotes(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\"" || ch == "\\" || ch == "$" || ch == "`" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Streaming scan

    private static func scan(
        host: String, directory: URL, encodedScript: String, acceptExhaustedHeaders: Bool
    ) -> (entry: SessionEntry?, resolvedPath: String?, needsEscalation: Bool, stoppedAt: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            host,
            "echo \(encodedScript) | base64 -d | /bin/sh",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("ssh launch failed for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (nil, nil, false, 0)
        }

        // Kill the connection rather than let it hang the launcher. Terminating
        // is also how the happy path ends — see the `break readLoop` below.
        //
        // It is a wall clock from process start, not a stall detector, so it
        // also kills a scan that is progressing but slow: a narrow link against
        // base64-inflated headers, or the escalated window. That lands on the
        // same nil as a broken host.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        var found: SessionEntry?
        var needsEscalation = false
        /// 1-based position of the candidate the loop stopped on.
        var seen = 0
        // Named apart from `resolvedPath(fromLine:)`: a local of that name
        // shadows the function inside this scope, which the compiler catches
        // here but would not if the call ever moved.
        var remoteResolvedPath: String?
        var carry = Data()
        let handle = pipe.fileHandleForReading

        readLoop: while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            carry.append(chunk)

            var searchStart = carry.startIndex
            while let newline = carry[searchStart...].firstIndex(of: 0x0A) {
                let line = Data(carry[searchStart..<newline])
                searchStart = newline + 1
                if let path = resolvedPath(fromLine: line) {
                    // Empty means the directory does not exist remotely, which
                    // is a real answer and must not be retried as a path.
                    remoteResolvedPath = path.isEmpty ? nil : path
                    continue
                }
                seen += 1
                switch classify(line: line, directory: directory) {
                case .resumable(let entry):
                    found = entry
                    break readLoop
                case .headerExhausted(let entry):
                    // Stop HERE rather than reading on. Which candidate wins is
                    // decided by order, so a later survivor cannot be accepted
                    // while an earlier one is still unclassified.
                    if acceptExhaustedHeaders { found = entry } else { needsEscalation = true }
                    break readLoop
                case .filtered, .malformed:
                    continue
                }
            }
            carry = Data(carry[searchStart...])
        }

        // Nothing after the survivor is wanted; closing the read end makes the
        // remote's next `printf` fail so it stops producing headers we would
        // only discard.
        try? handle.close()
        deadline.cancel()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        // Two different nils, and the launcher cannot tell them apart — both
        // just open a fresh session, which IS the bug this file was written to
        // fix. So the log has to, or the feature regressing looks exactly like
        // the feature never having been added.
        //
        // The status is only read on the empty path. On a hit we usually
        // terminated ssh mid-stream, but not always — a survivor on the last
        // line it emits can leave ssh exiting 0 on its own — so the status
        // there says nothing about the lookup either way.
        if found == nil, !needsEscalation {
            let status = process.terminationStatus
            if status == 0 {
                logger.notice("no resumable remote session under \(directory.path, privacy: .private) on \(host, privacy: .public)")
            } else {
                logger.error("remote session lookup on \(host, privacy: .public) failed: ssh exited \(status)")
            }
        }
        return (found, remoteResolvedPath, needsEscalation, seen)
    }

    /// The leading `P <path>` line, or nil for anything else. Returns an empty
    /// string when the remote could not enter the directory — distinct from
    /// nil, which means this was not the resolved-path line at all.
    static func resolvedPath(fromLine line: Data) -> String? {
        guard let text = String(data: line, encoding: .utf8), text.hasPrefix("P ") else {
            return nil
        }
        return String(text.dropFirst(2))
    }

    /// What one `<id> <mtime> <base64 header>` line turned out to be.
    ///
    /// `headerExhausted` is the case the first revision did not have, and its
    /// absence was a hole rather than a simplification: a header window that
    /// ends before the first `type: "user"` record yields a scanner that saw no
    /// `entrypoint`, which reads as "not automated" and is indistinguishable
    /// from a real session. It carries the entry it WOULD have produced so the
    /// widest window can accept it, which is what `extractMetadata` does at its
    /// own ceiling.
    enum Candidate: Equatable {
        case resumable(SessionEntry)
        case headerExhausted(SessionEntry)
        case filtered
        case malformed
    }

    /// Non-private so the logic probe can pin the filter. This is where a
    /// user's real session is either found or silently discarded, and the whole
    /// SSH half of the feature is unreachable from a probe otherwise.
    static func classify(line: Data, directory: URL) -> Candidate {
        guard let text = String(data: line, encoding: .utf8) else { return .malformed }
        let fields = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return .malformed }

        let id = String(fields[0])
        guard UUID(uuidString: id) != nil else { return .malformed }
        // `Data(base64Encoded: "")` is a non-nil EMPTY Data — measured, not
        // reasoned — so the decode alone does not reject a line whose header
        // field is blank. Produced by a remote with no `base64`, a zero-length
        // JSONL, or a `head` that died mid-pipeline.
        //
        // `!header.isEmpty` is now REDUNDANT and kept as a near-guard: empty
        // bytes scan to zero records and the `sawAnyRecord` check below would
        // reject them anyway. A reviewer measured that deleting this changes
        // no outcome. It stays because it names the case at the point the case
        // is created, not because anything depends on it.
        guard let header = Data(base64Encoded: String(fields[2])), !header.isEmpty else {
            return .malformed
        }

        // The SAME scanner the local loader runs, over bytes fetched off the
        // other machine — see `ClaudeSessionHistory.HeaderScanner` for why the
        // filters must not be re-expressed in the remote shell.
        var scanner = ClaudeSessionHistory.HeaderScanner()
        var start = header.startIndex
        while let newline = header[start...].firstIndex(of: 0x0A) {
            scanner.consume(Data(header[start..<newline]))
            start = newline + 1
            if scanner.stopScan { break }
        }
        // The trailing fragment is deliberately NOT consumed. Whenever the file
        // is larger than the window it is a cut record, and parsing a cut
        // record is what the local scanner refuses too. When the file is
        // SMALLER than the window an unterminated tail would be complete —
        // `extractMetadata` asks the filesystem for one byte to tell those
        // apart, and there is no EOF to ask about here — so that record is
        // dropped. It costs at most the last record of a transcript the CLI
        // wrote without a trailing newline, which is not a shape it produces.

        let metadata = scanner.result
        guard !metadata.isBackgroundScheduled, !metadata.isAutomated else { return .filtered }

        let seconds = TimeInterval(fields[1]) ?? 0
        let entry = SessionEntry(
            // The local store, for a remote session, on purpose: it is keyed by
            // session id, and a name the user typed into Rename belongs to the
            // conversation rather than to the machine running it. Same override
            // `loadSessionsFromDir` applies, so a remote row and a local one
            // cannot disagree about a renamed session's label.
            id: id,
            title: SessionTitleStore.title(forSessionId: id) ?? metadata.title,
            timestamp: seconds > 0 ? Date(timeIntervalSince1970: seconds) : .distantPast,
            projectDirectory: directory
        )
        // Bytes that parsed as nothing at all are not a truncated transcript,
        // they are not a transcript — a partially written file from a crashed
        // CLI, something copied into the folder, a `.jsonl` with no newline in
        // the whole window. Collapsing that into `headerExhausted` is what a
        // reviewer found: the widest window ACCEPTS an exhausted header, so one
        // such file at the top of `ls -1t` would be offered as an "Untitled"
        // session, `--resume`d, and exit 1 — and because the scan stops at the
        // first unclassified candidate, it would block that folder for good
        // while real sessions sat two entries below it.
        //
        // Known residual, recorded rather than fixed because fixing it trades
        // back the bug above. Zero parsed records ALSO describes a transcript
        // whose very first record is larger than the window — a shape
        // `metadataHeadSize` is explicitly sized against — and `.malformed`
        // neither escalates nor is revisited by the skip, so such a session is
        // missed. It is a MISS and not a block: the scan continues to the next
        // candidate, where the older behaviour stopped dead on the first
        // unclassified one and failed the whole folder. Closing it needs
        // `classify` to know its window so zero-records can escalate at the
        // head and reject at the ceiling.
        guard scanner.sawAnyRecord else { return .malformed }

        // `sawUserRecord` is the scanner's own evidence that it reached the
        // header. Without it, `isAutomated == false` only means "no `sdk-*`
        // entrypoint was SEEN", which is a different claim.
        return scanner.sawUserRecord ? .resumable(entry) : .headerExhausted(entry)
    }
}
