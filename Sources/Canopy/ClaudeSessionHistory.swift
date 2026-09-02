import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionHistory")

struct SessionEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let timestamp: Date
    let projectDirectory: URL

    var projectName: String { GitWorktree.projectDisplayName(for: projectDirectory) }
}

enum ClaudeSessionHistory {
    private static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// How many sessions the history list holds, counted in rows that
    /// SURVIVE the filters in `loadAllSessions` — never in files read.
    ///
    /// The cap used to be the second thing, and the gap between them widens
    /// the more the machine is used. Automated runs (`entrypoint: "sdk-*"` —
    /// sub-agents, `/security-review`, title generation) each write a JSONL
    /// and are dropped on sight, but a budget spent before the filter is
    /// spent all the same: measured 2026-09-03 over 1,555 openable sessions,
    /// the newest 50 FILES held 41 automated ones and yielded **9 rows**, so
    /// 82% of the list went to sessions that can never be shown. The symptom
    /// is a sidebar that empties as sub-agent use grows, with nothing else to
    /// point at.
    ///
    /// Non-private, with `maxSessionsToScan`, so the probe can assert the one
    /// relationship between them rather than restating either value.
    static let maxSessionsToKeep = 50

    /// Ceiling on files read while collecting `maxSessionsToKeep`, so a
    /// corpus with a poor survival ratio cannot turn one refresh into a walk
    /// of the whole tree.
    ///
    /// Reaching the target costs `1 / ratio` files, and that ratio is a
    /// property of how the machine is used rather than a constant — measured
    /// here at ~18%, so 50 rows cost 275 files and 25.6 MiB of header reads,
    /// against 50 files and 4.2 MiB before. This sits ~1.5× above that walk;
    /// its own worst case, 400 files, is 38.3 MiB. Both `loadAllSessions`
    /// callers `Task.detached`, so none of it is on the main thread —
    /// `loadSessionsFromDir` is the synchronous path, and it is uncapped for
    /// a separate reason argued on `metadataMaxScanSize`.
    ///
    /// Reaching it returns a SHORT list, which is the same silent-shrink
    /// symptom this pair exists to fix, so that case logs rather than passing
    /// unremarked.
    ///
    /// Must exceed `maxSessionsToKeep` — pinned by the probe. At equality the
    /// walk stops at the exact point a run with zero drops would have filled
    /// the list, so any drop at all costs a row, which is the bug above with
    /// a different constant on it. The margin is what absorbs the drops, and
    /// how much margin is enough is the survival ratio measured above.
    static let maxSessionsToScan = 400

    /// Mirrors the current Claude CLI encoding: every character that is not a letter,
    /// digit, or `_` collapses to `-`. Examples: `/.config` → `--config`,
    /// `/Canopy Companion` → `-Canopy-Companion`.
    static func encodePath(_ path: String) -> String {
        encodePath(path, legacyDotAndSpace: false)
    }

    /// Legacy CLI encoding that preserved `.` and spaces inside components.
    /// Still needed because `~/.claude/projects/` contains folders written by older
    /// CLI versions (e.g. `-Users-hiko-Documents-repos-Personal-Canopy Companion`).
    private static func encodePathLegacy(_ path: String) -> String {
        encodePath(path, legacyDotAndSpace: true)
    }

    private static func encodePath(_ path: String, legacyDotAndSpace: Bool) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let mapped = components.map { component -> String in
            String(component.map { ch -> Character in
                if ch.isLetter || ch.isNumber || ch == "_" { return ch }
                if legacyDotAndSpace, ch == "." || ch == " " { return ch }
                return "-"
            })
        }
        return "-" + mapped.joined(separator: "-")
    }

    /// Every folder-name variant that may hold sessions for `path`, in preference order.
    /// Current CLI encoding is tried first; legacy form is included only when it differs
    /// and still points at a real folder on disk. Both must be consulted because users
    /// can have sessions written by multiple CLI versions for the same directory.
    static func encodedFolderCandidates(for path: String) -> [String] {
        let strict = encodePath(path)
        let legacy = encodePathLegacy(path)
        return strict == legacy ? [strict] : [strict, legacy]
    }

    /// True when a transcript for `id` exists under any encoding variant of
    /// `directory`. Used by launch restore to drop sessions whose JSONL is
    /// gone.
    ///
    /// What a restored session with a missing JSONL would actually do is NOT
    /// established, and two rounds of review each replaced one confident
    /// wrong answer with another, so the claim is retired rather than
    /// re-stated. What IS known: invoking the CLI directly with an
    /// unresolvable `--resume` fails loudly (measured on 2.1.217 — exit 1,
    /// `{"subtype":"error_during_execution"}`), but Canopy does not take that
    /// path; the id reaches `extension.js`, and every brand-new Canopy session
    /// runs on a placeholder resumeId with no JSONL and starts a fresh
    /// conversation instead of failing (see `SessionStore.openNew`). Dropping
    /// the pane here means the question never has to be answered. Both
    /// encodings are consulted for the same reason
    /// `encodedFolderCandidates` exists: older CLI versions wrote the other
    /// folder name for the same directory.
    static func sessionFileExists(id: String, directory: URL) -> Bool {
        for folder in encodedFolderCandidates(for: directory.path) {
            let url = claudeDir
                .appendingPathComponent(folder)
                .appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    /// Decode encoded project directory name back to path.
    /// Uses greedy filesystem walk to resolve ambiguous `-` separators.
    /// Matching Sessylph's approach.
    static func decodePath(_ encoded: String) -> String {
        guard encoded.count > 1 else { return "/" }

        let parts = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let tokens = Array(parts.dropFirst())

        // Merge empty tokens with next token as dot-prefixed:
        // ["Users", "hiko", "", "config"] → ["Users", "hiko", ".config"]
        var segments: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].isEmpty {
                i += 1
                if i < tokens.count {
                    segments.append("." + tokens[i])
                }
            } else {
                segments.append(tokens[i])
            }
            i += 1
        }

        // Greedy filesystem walk: try joining multiple segments with `-` to find longest match
        let fm = FileManager.default
        var resolved = ""
        i = 0

        while i < segments.count {
            var bestLen = 1
            let maxJ = min(segments.count, i + 6)
            for j in stride(from: maxJ, through: i + 1, by: -1) {
                let component = segments[i..<j].joined(separator: "-")
                let candidate = resolved + "/" + component
                if fm.fileExists(atPath: candidate) {
                    bestLen = j - i
                    break
                }
            }

            if bestLen == 1, !fm.fileExists(atPath: resolved + "/" + segments[i]) {
                let remaining = segments[i...].joined(separator: "-")
                if let entries = try? fm.contentsOfDirectory(atPath: resolved) {
                    let normalized = remaining.replacingOccurrences(of: ".", with: "-")
                    if let match = entries.first(where: {
                        $0.replacingOccurrences(of: ".", with: "-") == normalized
                    }) {
                        resolved += "/" + match
                        break
                    }
                    resolved += "/" + segments[i]
                    i += 1
                    continue
                }
                resolved += "/" + remaining
                break
            }

            let component = segments[i..<(i + bestLen)].joined(separator: "-")
            resolved += "/" + component
            i += bestLen
        }

        return resolved.isEmpty ? "/" : resolved
    }

    /// Load sessions for a specific working directory.
    /// Consults every encoded folder variant (current + legacy) so sessions written
    /// by older CLI versions still surface. Results are deduplicated by session id.
    static func loadSessions(for directory: URL) -> [SessionEntry] {
        var seen = Set<String>()
        var entries: [SessionEntry] = []
        for encoded in encodedFolderCandidates(for: directory.path) {
            let projectDir = claudeDir.appendingPathComponent(encoded)
            for entry in loadSessionsFromDir(projectDir, projectDirectory: directory) where seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Load sessions across all projects, sorted by most recent.
    /// Collects file metadata first (no file reads), sorts by date, then
    /// parses headers newest-first until `maxSessionsToKeep` sessions have
    /// SURVIVED the filters below — bounded by `maxSessionsToScan`.
    static func loadAllSessions() -> [SessionEntry] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [] }

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir.path) else { return [] }

        // Phase 1: collect all JSONL file metadata (no content reads)
        var candidates: [(path: String, modDate: Date, sessionId: String, projectEncoded: String)] = []

        for projectEncoded in projectDirs {
            guard projectEncoded != "-" else { continue }
            // Skip claude-mem observer sessions (auto-created by hooks, not user sessions)
            guard !projectEncoded.hasSuffix("observer-sessions") else { continue }

            let projectPath = claudeDir.path + "/" + projectEncoded
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = String(file.dropLast(6))
                guard UUID(uuidString: sessionId) != nil else { continue }

                let filePath = projectPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date
                else { continue }

                candidates.append((filePath, modDate, sessionId, projectEncoded))
            }
        }

        // Phase 2 + 3: newest first, then read headers until enough rows
        // SURVIVE — the drops below are what the budget must not be spent on.
        // Each survivor resolves its on-disk project dir via
        // `resolveProjectPath` (extracted cwd vs storage-folder encoding).
        candidates.sort { $0.modDate > $1.modDate }

        let selection = selectNewest(
            candidates,
            keep: maxSessionsToKeep,
            scanLimit: maxSessionsToScan
        ) { candidate -> SessionEntry? in
            let metadata = extractMetadata(fromPath: candidate.path)
            guard !metadata.isBackgroundScheduled, !metadata.isAutomated else { return nil }
            let projectPath = resolveProjectPath(
                extractedCwd: metadata.cwd,
                projectEncoded: candidate.projectEncoded
            )
            guard fm.fileExists(atPath: projectPath) else { return nil }
            let title = SessionTitleStore.title(forSessionId: candidate.sessionId)
                ?? metadata.title

            return SessionEntry(
                id: candidate.sessionId,
                title: title,
                timestamp: candidate.modDate,
                projectDirectory: URL(fileURLWithPath: projectPath)
            )
        }

        // Stopping EARLY is the whole signal: a walk that reached the end of
        // the candidates read everything there was, and a short list then just
        // means the disk holds nothing more. `scanned >= maxSessionsToScan`
        // cannot tell those apart when the corpus happens to be exactly that
        // size, which is the distinction `selectNewest` returns `scanned` for.
        if selection.kept.count < maxSessionsToKeep, selection.scanned < candidates.count {
            logger.notice("""
                Session scan hit its ceiling: \(selection.scanned, privacy: .public) files read, \
                \(selection.kept.count, privacy: .public) of \(maxSessionsToKeep, privacy: .public) rows kept, \
                \(candidates.count, privacy: .public) candidates on disk
                """)
        }

        return selection.kept
    }

    /// Walk `candidates` in order, keeping whatever `evaluate` accepts, and
    /// stop at whichever comes first: `keep` accepted, or `scanLimit`
    /// evaluated.
    ///
    /// The first of those two is the whole point, and it is the half a
    /// `prefix(keep)` placed ahead of the filter silently gets wrong: that
    /// stops on items READ, so every rejected item costs a row. `scanLimit`
    /// only bounds the damage when nearly everything is rejected.
    ///
    /// Pure, and generic at both ends, so the probe can pin that contract
    /// with a synthetic predicate rather than a `~/.claude/projects/` tree.
    /// `scanned` comes back because "short list" and "short list because we
    /// gave up" are different states, and only the caller can say which one
    /// deserves a log line.
    static func selectNewest<Candidate, Kept>(
        _ candidates: [Candidate],
        keep: Int,
        scanLimit: Int,
        evaluate: (Candidate) -> Kept?
    ) -> (kept: [Kept], scanned: Int) {
        var kept: [Kept] = []
        var scanned = 0
        for candidate in candidates {
            if kept.count >= keep || scanned >= scanLimit { break }
            scanned += 1
            if let value = evaluate(candidate) { kept.append(value) }
        }
        return (kept, scanned)
    }

    /// Walk every JSONL across `~/.claude/projects/` and return a map of
    /// local session id → cloud session id, populated from `teleported-from`
    /// header lines. Used by the sidebar to dedupe cloud rows that have
    /// already been teleported into local sessions.
    ///
    /// Cheap: reads only the last 64 KB of each file — `saveSession` writes
    /// `teleported-from` after the messages, so it lives at the tail. See
    /// `extractTeleportedFrom`.
    static func loadTeleportedFromMap() -> [String: String] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [:] }
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir.path) else { return [:] }
        var map: [String: String] = [:]

        for projectEncoded in projectDirs {
            guard projectEncoded != "-" else { continue }
            let projectPath = claudeDir.path + "/" + projectEncoded
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = String(file.dropLast(6))
                guard UUID(uuidString: sessionId) != nil else { continue }
                let filePath = projectPath + "/" + file
                guard let cloudId = extractTeleportedFrom(at: filePath) else { continue }
                map[sessionId] = cloudId
            }
        }
        return map
    }

    /// Scan a JSONL file's TAIL for a `teleported-from` header line and
    /// return the cloud session id (`remoteSessionId`) if present.
    ///
    /// The CC extension writes `teleported-from` AFTER messages and the
    /// summary in `c1.saveSession`, so it's always within the last few KB
    /// of the file. We read just the tail (~64 KB) for speed — reading
    /// every full JSONL across 300+ files would block startup.
    private static func extractTeleportedFrom(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Get file size to seek to tail.
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }
        let tailLength: UInt64 = 65_536 // 64 KB
        let offset = fileSize > tailLength ? fileSize - tailLength : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let chunk = try? handle.readToEnd(),
              let text = String(data: chunk, encoding: .utf8) else { return nil }

        // Skip the first (partial) line if we didn't start at offset 0.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let startIndex = offset == 0 ? 0 : 1
        guard startIndex < lines.count else { return nil }
        for rawLine in lines[startIndex...].reversed() {
            guard rawLine.contains("teleported-from") else { continue }
            guard let lineData = rawLine.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  parsed["type"] as? String == "teleported-from",
                  let remoteId = parsed["remoteSessionId"] as? String
            else { continue }
            return remoteId
        }
        return nil
    }

    // MARK: - Internal

    private static func loadSessionsFromDir(_ projectDir: URL, projectDirectory: URL) -> [SessionEntry] {
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            )
            let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }

            var entries: [SessionEntry] = []
            for file in jsonlFiles {
                let sessionId = file.deletingPathExtension().lastPathComponent
                if sessionId.hasPrefix("agent-") { continue }
                guard UUID(uuidString: sessionId) != nil else { continue }

                let metadata = extractMetadata(fromPath: file.path)
                guard !metadata.isBackgroundScheduled, !metadata.isAutomated else { continue }

                let title = SessionTitleStore.title(forSessionId: sessionId)
                    ?? metadata.title
                let mtime: Date
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    mtime = attrs[.modificationDate] as? Date ?? Date.distantPast
                } catch {
                    logger.warning("Failed to get attributes for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    mtime = Date.distantPast
                }

                entries.append(SessionEntry(
                    id: sessionId,
                    title: title,
                    timestamp: mtime,
                    projectDirectory: projectDirectory
                ))
            }
            return entries.sorted { $0.timestamp > $1.timestamp }
        } catch {
            logger.error("Failed to read sessions: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Count user + assistant messages in a session transcript file.
    static func countMessages(sessionId: String, directory: URL) -> Int {
        let fm = FileManager.default
        var filePath: String?
        for encoded in encodedFolderCandidates(for: directory.path) {
            let candidate = claudeDir
                .appendingPathComponent(encoded)
                .appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: candidate) {
                filePath = candidate
                break
            }
        }
        guard let filePath, let handle = FileHandle(forReadingAtPath: filePath) else { return 0 }
        defer { try? handle.close() }

        var count = 0
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            if type == "user" || type == "assistant" { count += 1 }
        }
        return count
    }

    /// User-typed prompts from a session JSONL, for seeding title-generation
    /// context on resume. Skips meta records, slash-command wrappers, and
    /// tool-result-only user lines. Callers cap the result (see
    /// `ShimProcess.trimmedPromptHistory`).
    static func loadUserPrompts(sessionId: String, directory: URL) -> [String] {
        let fm = FileManager.default
        for encoded in encodedFolderCandidates(for: directory.path) {
            let candidate = claudeDir
                .appendingPathComponent(encoded)
                .appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: candidate) {
                return loadUserPrompts(atPath: candidate)
            }
        }
        return []
    }

    /// Bounded read: session JSONLs grow to tens of MB and this runs in
    /// `ShimProcess.init` on the main thread (`loadTeleportedFromMap` bounds
    /// itself the same way, at a 64KB tail). Head chunk keeps the first prompt
    /// (the session's goal), tail chunk keeps the recent ones.
    ///
    /// **This is still a byte window, and `extractMetadata` is no longer one.**
    /// The loss needs the file to exceed `chunkSize * 2` (or the branch below
    /// reads it whole) *and* no prompt-yielding user record inside the first
    /// `chunkSize` — note "prompt-yielding", not "present": `parseUserPrompts`
    /// filters meta and `<command-` lines, so a record can be in the window and
    /// still contribute nothing. Measured over the openable sessions, 41 of
    /// 1,049 lose their first prompt here, 24 of them among the 31 that
    /// escalate in `extractMetadata`; the `/security-review` file that prompted
    /// the rewrite is not one of them, at 240,633 bytes it is read whole. Left
    /// alone deliberately: this feeds recap and title generation rather than
    /// the sidebar's automated-session filter, so it is a different symptom
    /// and deserves its own change rather than a widening of that one.
    static func loadUserPrompts(atPath path: String) -> [String] {
        let chunkSize = 131_072
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return [] }

        if fileSize <= UInt64(chunkSize * 2) {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.readToEnd()
            else { return [] }
            return parseUserPrompts(String(decoding: data, as: UTF8.self))
        }

        guard (try? handle.seek(toOffset: 0)) != nil,
              let headData = try? handle.read(upToCount: chunkSize)
        else { return [] }
        let headPrompts = parseUserPrompts(String(decoding: headData, as: UTF8.self))
        // Tail starts one byte early so dropping through the first newline is
        // always legitimate: if the nominal window boundary happens to land
        // exactly on a line start, that extra byte is the previous line's
        // terminator and the full boundary line survives. Head may end
        // mid-line (the partial line fails JSON parse and is skipped).
        guard (try? handle.seek(toOffset: fileSize - UInt64(chunkSize) - 1)) != nil,
              let tailData = try? handle.readToEnd()
        else { return headPrompts }
        var tail = String(decoding: tailData, as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: newline)...])
        }
        let tailPrompts = parseUserPrompts(tail)
        guard let first = headPrompts.first else { return tailPrompts }
        return [first] + tailPrompts
    }

    private static func parseUserPrompts(_ text: String) -> [String] {
        // `<command-` covers both `<command-message>` (line 1 of a
        // slash-command record) and `<command-name>`.
        let skipPrefixes = [
            "Caveat:", "<command-", "<local-command",
            "<task-notification", "<system-reminder",
            "[Request interrupted",
            "This session is being continued",
            // Canopy's own prompt-cache keep-alive. It is a REAL user record
            // in the JSONL, and this loader reads a TAIL window — so a
            // session kept warm overnight is dominated by refreshes, and the
            // title generator would be fed those instead of the user's work.
            // Derived from the constant so the two cannot drift.
            KeepAliveGate.promptPrefix,
        ]
        var prompts: [String] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "user",
                  json["isMeta"] as? Bool != true,
                  json["isCompactSummary"] as? Bool != true,
                  let message = json["message"] as? [String: Any]
            else { continue }

            var extracted: String?
            if let content = message["content"] as? String {
                extracted = content
            } else if let contentArr = message["content"] as? [[String: Any]] {
                // Text blocks only — tool_result blocks have no top-level "text".
                let joined = contentArr
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                if !joined.isEmpty { extracted = joined }
            }
            guard let raw = extracted else { continue }
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !skipPrefixes.contains(where: { trimmed.hasPrefix($0) })
            else { continue }
            // Pasted-image placeholders: strip the tokens but keep the user's
            // words ("[Image #1] fix this layout" → "fix this layout"); a
            // placeholder-only prompt becomes empty and is skipped.
            if trimmed.contains("[Image #") {
                trimmed = trimmed
                    .replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
            }
            prompts.append(String(trimmed.prefix(500)))
        }
        return prompts
    }

    /// True when the JSONL was created by Claude Code's scheduled-task runner
    /// (`queue-operation` / `enqueue` whose `content` contains `<scheduled-task`).
    static func isBackgroundScheduledSession(atPath path: String) -> Bool {
        extractMetadata(fromPath: path).isBackgroundScheduled
    }

    /// True when the JSONL was created by a non-interactive `claude -p` / SDK run
    /// (`entrypoint: "sdk-*"` — sdk-cli, sdk-py, sdk-ts) — memory observers,
    /// `/ship-it` sub-agents, plugin background reviews, etc.
    static func isAutomatedSession(atPath path: String) -> Bool {
        extractMetadata(fromPath: path).isAutomated
    }

    /// The sidebar row's label before `SessionTitleStore` gets a say: the
    /// session's `ai-title` if one was written, else its first user message,
    /// else `"Untitled"`. Exposed for the sidebar logic probe.
    static func title(atPath path: String) -> String {
        extractMetadata(fromPath: path).title
    }

    /// The session's *current* cwd — the directory the CLI would resume into.
    /// Prefers the latest `relocated` event's `relocatedCwd` over the initial
    /// `cwd` field so sessions that were moved into a git worktree resolve to
    /// the right project folder. Exposed for the sidebar logic probe.
    static func cwd(atPath path: String) -> String? {
        extractMetadata(fromPath: path).cwd
    }

    /// Resolve the on-disk project directory for a session, given the extracted
    /// cwd (may be stale after middle-gap relocations, or encoding-drifted for
    /// non-ASCII paths) and the JSONL's storage folder (authoritative for the
    /// CLI's current resume location). Exposed for the sidebar logic probe.
    ///
    /// Agreement (extracted cwd's encoded form matches `projectEncoded`) trusts
    /// the extracted cwd. Mismatch covers two cases: a middle-gap relocation
    /// the head+tail scan missed, or CLI encoding that disagrees with our
    /// `encodePath` (e.g. non-ASCII Unicode normalization drift). Prefer the
    /// decoded storage folder when it resolves on disk (relocation); otherwise
    /// fall back to the extracted cwd — a real path is better than a
    /// synthesized decode that no longer exists.
    static func resolveProjectPath(
        extractedCwd: String?,
        projectEncoded: String,
        fileManager: FileManager = .default
    ) -> String {
        if let cwd = extractedCwd,
           encodedFolderCandidates(for: cwd).contains(projectEncoded)
        {
            return cwd
        }
        let decoded = decodePath(projectEncoded)
        if fileManager.fileExists(atPath: decoded) {
            return decoded
        }
        if let cwd = extractedCwd {
            return cwd
        }
        return decoded
    }

    /// Bytes requested on the first read of every session, and the size of
    /// each escalation chunk after it — a smaller file reads less. Sized so
    /// large base64 image attachments don't push `ai-title` past the window.
    /// Non-private for the same reason as `metadataMaxScanSize`.
    static let metadataHeadSize = 131_072

    /// Ceiling on the escalated scan (see `extractMetadata`) — sixteen head
    /// chunks.
    ///
    /// **Measure this against the files the loaders can actually open, and
    /// nothing else — every wrong answer this comment has carried came from
    /// measuring a different set.** Both walk exactly two levels
    /// (`~/.claude/projects/<encoded>/<uuid>.jsonl`), so nested `subagents/`
    /// trees never appear; `loadAllSessions` additionally skips a directory
    /// named `-` and any name ending `observer-sessions`, and both require a
    /// UUID filename, which is what excludes `agent-*.jsonl`. Miss the `-`
    /// skip alone and the population grows by 284 files and the answer below
    /// changes. Measured 2026-08-13 over the resulting 1,047 files: 31
    /// escalate past one head chunk, **every one of them closes its header
    /// inside the ceiling**, and the largest needs **1,056,552 bytes** — so
    /// this ceiling carries 1.98× the largest real header.
    ///
    /// It is not tightened toward that figure because the same CLI mechanism
    /// writes far larger headers in files these loaders happen not to open:
    /// 1,829,543 bytes in a `subagents/agent-acompact-*.jsonl`, and
    /// 13,121,983 under `observer-sessions` (a 6.5 MB `queue-operation`
    /// followed by a 6.5 MB user record). Only the population filter
    /// separates those from the openable set, and the cliff is silent — the
    /// row degrades to "Untitled" *and* escapes the `sdk-*` filter.
    ///
    /// Non-private so the sidebar logic probe can build a fixture that
    /// exceeds it rather than hardcoding a copy that could drift.
    static let metadataMaxScanSize = 2_097_152

    /// Read the header records of a JSONL and pull out everything the sidebar
    /// needs from them. Returns the cwd too so session discovery can skip
    /// decoding the folder name. Also scans up to the last 32KB — whatever of
    /// it the line scan did not already cover — for `type: "relocated"`
    /// events, so a session moved into a git worktree mid-way resolves to its
    /// current cwd, not the launch cwd.
    ///
    /// `isAutomated` flags non-interactive `claude -p` / SDK-driven runs
    /// (memory observers, sub-agents from `/ship-it`, plugin background
    /// reviews, etc.), detected via the `entrypoint: "sdk-*"` marker the
    /// CLI/SDKs write on their user lines (`sdk-cli`, `sdk-py`, `sdk-ts`).
    ///
    /// **Scanning is by whole line, never by byte prefix, and the byte budget
    /// is a floor rather than a hard stop.** A JSONL record is only usable
    /// when the entire line is present, and the CLI writes single records far
    /// larger than any fixed window: a `/security-review` run opens with a
    /// ~90KB `queue-operation` holding the whole diff, and its `type: "user"`
    /// record — the one carrying `entrypoint`, `cwd` and the prompt — starts
    /// at byte 91,815 and runs 92,028 bytes. A flat 128KB read therefore ended
    /// *inside* that record, `JSONSerialization` rejected the fragment, and
    /// the file looked like it had no user line at all: no `entrypoint` (so
    /// the `sdk-*` filter never fired) and no title. Several such rows sat in
    /// the sidebar as "Untitled" — two symptoms, one cause.
    ///
    /// The scan escalates — one chunk at a time, to `metadataMaxScanSize` —
    /// only while it has *not yet parsed a single* `type: "user"` record.
    /// That is the signal that the window never reached the header, rather
    /// than that the header was uninteresting; a session whose first user
    /// record carries no text still ends the escalation, which is a real hole
    /// and not one worth widening the gate for (measured: 0 of 1,047 local
    /// sessions have a text-less first user record; the probe pins the hole so
    /// widening it can't happen by accident). A file that blows the ceiling
    /// keeps whatever it parsed below it, which for a single over-ceiling
    /// leading record means no entrypoint and "Untitled".
    ///
    /// **Per-file line-scan cost is unchanged for a session that does not
    /// escalate, but the refresh cost is not, because the escalating sessions
    /// cluster in the recent window the loader actually reads.** (The tail
    /// window can start earlier than it used to, costing up to 32KB more on a
    /// file that stops mid-record; corpus-wide the tail read shrinks, because
    /// escalated files start theirs later.) Over the openable population
    /// (see `metadataMaxScanSize`) 31 of 1,047 escalate, and the whole-corpus
    /// read moves 105,103,370 → 112,112,155 bytes; over the newest 50 FILES —
    /// the window `loadAllSessions` read at the time — 15 escalate and it
    /// moves 5,536,876 → 7,365,828, because a day spent running
    /// `/security-review` fills that window with exactly the sessions that
    /// need escalating. That window is wider now, and disproportionately so
    /// for this cost: it reads until `maxSessionsToKeep` rows survive, and
    /// the files it therefore reads on top are the automated ones, which are
    /// the escalating ones. **The uncapped path is also the main-thread
    /// one**: `loadAllSessions`'s two callers both `Task.detached` and it
    /// caps its scan at `maxSessionsToScan`, while `loadSessionsFromDir` is
    /// reached synchronously from `LauncherView.latestSession(for:)` — a
    /// SwiftUI `View`, so main-actor — over every JSONL in one project folder.
    /// Measured worst *project* folder here: 159 files, 16.6 → 17.8 MiB. The
    /// skip list lives on `loadAllSessions`, not here, so the worst folder
    /// this path could be handed is `observer-sessions` itself at 1,056 files,
    /// 111.9 → 1,045.2 MiB — which is the argument for keeping that list on
    /// the caller rather than moving it down.
    private static func extractMetadata(fromPath path: String) -> (title: String, cwd: String?, isBackgroundScheduled: Bool, isAutomated: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ("Untitled", nil, false, false)
        }
        defer { try? handle.close() }

        var aiTitle: String?
        var firstUserMessage: String?
        var firstCwd: String?
        var lastRelocatedCwd: String?
        var isBackgroundScheduled = false
        var entrypoint: String?
        var sawUserRecord = false
        var stopScan = false

        // Whole lines only, so JSON is parsed straight from the line's bytes.
        // The old lossy String decode existed to survive a window boundary
        // landing inside a multibyte sequence; complete lines can't have one.
        // It also repaired bytes that were invalid *on disk*, which this does
        // not — such a line is now rejected outright. That is the better
        // failure (a mangled title is worse than none) but it is a real
        // behaviour change, and on a header line it costs the title and the
        // `sdk-*` filter together, the same pair this function exists to fix.
        func consume(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            if firstCwd == nil, let value = json["cwd"] as? String, !value.isEmpty {
                firstCwd = value
            }

            if entrypoint == nil, let value = json["entrypoint"] as? String, !value.isEmpty {
                entrypoint = value
            }

            guard let type = json["type"] as? String else { return }

            // `type: "relocated"` is the CLI's own signal that the session
            // moved to a new project folder (typically a git worktree). The
            // JSONL is stored under the encoded *relocated* cwd, so this
            // must beat the stale launch cwd captured above. Later entries
            // override earlier ones.
            if type == "relocated",
               let value = json["relocatedCwd"] as? String, !value.isEmpty
            {
                lastRelocatedCwd = value
            }

            if !isBackgroundScheduled,
               type == "queue-operation",
               json["operation"] as? String == "enqueue",
               let content = json["content"] as? String,
               content.contains("<scheduled-task")
            {
                isBackgroundScheduled = true
                // The only record whose *content* ends the scan. Do not add
                // cwd or title to that list — a scheduled-task enqueue can
                // appear after the first user line in some JSONL orderings,
                // so stopping on those would step over it. (The byte loop has
                // its own exit once a `user` record has parsed AND the head
                // chunk is behind it; that one is about the window, not about
                // what was found.)
                stopScan = true
            }

            if aiTitle == nil, type == "ai-title",
               let value = json["aiTitle"] as? String, !value.isEmpty
            {
                aiTitle = value
            }

            guard type == "user" else { return }
            sawUserRecord = true

            if firstUserMessage == nil, let message = json["message"] as? [String: Any] {
                if let content = message["content"] as? String, !content.isEmpty {
                    firstUserMessage = String(content.prefix(100))
                } else if let contentArr = message["content"] as? [[String: Any]] {
                    let joined = contentArr.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !joined.isEmpty { firstUserMessage = String(joined.prefix(100)) }
                }
            }
        }

        var carry = Data()
        var scannedBytes = 0
        var atEOF = false

        while !stopScan, !atEOF, scannedBytes < metadataMaxScanSize {
            // Past the head chunk, keep going only while the header is still
            // out of reach — except that a non-empty `carry` may be a
            // COMPLETE final record rather than a fragment. Which one it is
            // depends solely on whether the file ends here, so ask, with a
            // single byte, instead of guessing. Without this a file whose
            // size is an exact multiple of the chunk loses its last record.
            if scannedBytes >= metadataHeadSize, sawUserRecord {
                if !carry.isEmpty { atEOF = handle.readData(ofLength: 1).isEmpty }
                break
            }

            let want = min(metadataHeadSize, metadataMaxScanSize - scannedBytes)
            let chunk = handle.readData(ofLength: want)
            scannedBytes += chunk.count
            // Only a zero-length read proves EOF. A short read implies it on a
            // local regular file and not necessarily anywhere else, so reading
            // one more time costs a syscall and removes an assumption.
            if chunk.isEmpty {
                atEOF = true
                break
            }
            carry.append(chunk)

            var searchStart = carry.startIndex
            while let newline = carry[searchStart...].firstIndex(of: 0x0A) {
                consume(Data(carry[searchStart..<newline]))
                searchStart = newline + 1
                if stopScan { break }
            }
            // Keep only the unterminated tail; the copy re-bases the indices.
            carry = Data(carry[searchStart...])
        }

        // A final record with no trailing newline is complete only at EOF.
        // Hitting the ceiling instead leaves a fragment, which is exactly what
        // must not be parsed.
        // `consume` silently rejects a line it cannot parse, so `carry` is NOT
        // cleared here even on success. These files are appended to by running
        // sessions, so "EOF" can mean "the CLI has not finished this record
        // yet" — clearing would fold an unparsed fragment into `consumedBytes`
        // below and hand the tail scan a mid-record start, which is the exact
        // hole that bound exists to close. Leaving it costs the tail scan one
        // re-read: for a record `consume` accepted that is exactly idempotent,
        // and relocation is last-wins. For one it REJECTED it is not — the
        // tail decodes lossily, so a `relocated` carrying a byte that is
        // invalid on disk can be accepted there after being refused here.
        // Measured, and left as is: `resolveProjectPath` checks the directory
        // exists before using it.
        if !stopScan, atEOF, !carry.isEmpty {
            consume(carry)
        }

        // Bytes consumed as WHOLE LINES — which is not the same as bytes read,
        // and the tail window below has to be bounded by this one. The line
        // scan almost always stops mid-record, and that record's leading bytes
        // are inside the read region while its tail is not; bounding the tail
        // at `scannedBytes` would start it mid-record, the boundary probe would
        // correctly call the remainder a fragment, and neither half would ever
        // look at it. A `relocated` event landing there would be lost — and it
        // is the tail scan's whole job not to lose one. Bounding here instead
        // starts the tail exactly on a line boundary. That also recovers a
        // record straddling the head chunk — but only while the file ends
        // within 32KB of it; past that `fileSize - tailSize` dominates and the
        // straddling record falls in the gap neither half reads, exactly as it
        // did before. The probe pins the naive bytes-read alternative, not the
        // pre-PR constant, which this fixture's size happens to survive.
        let consumedBytes = UInt64(scannedBytes - carry.count)

        // Sessions can be `relocated` many MB into the JSONL (e.g. a long
        // LSE-Core session that later cd into `.claude/worktrees/…`). The
        // head chunk misses that; the CLI still stores the JSONL under the
        // current encoded cwd, so returning the stale launch cwd here would
        // make `--resume` spawn the CLI in the wrong dir → CLI can't find
        // the JSONL → empty session with a fresh id (see `backfillResumeId`
        // in logs). Scan the tail for the latest relocation event.
        // On I/O failure we keep head-only data; `loadAllSessions`'s
        // encoded-folder verification still protects against a stale cwd.
        if !isBackgroundScheduled {
            var stage = "seekToEnd"
            do {
                let fileSize = try handle.seekToEnd()
                if fileSize > consumedBytes {
                    let tailSize: UInt64 = 32_768
                    let tailStart = max(consumedBytes, fileSize - min(tailSize, fileSize))
                    // Only drop the first tail line when `tailStart` lands
                    // mid-line. If the previous byte is `\n`, the first line
                    // is complete — dropping it would lose a `relocated`
                    // event that begins exactly at the window boundary.
                    // Offset 0 is a line start by definition and has no
                    // previous byte to probe. Reached whenever the scan
                    // consumed no whole line — any file with no newline in the
                    // region it read — and the file fits in one tail window.
                    // The probe's own `arrayContentJSONL` is that shape, so
                    // this runs on every CI build. Three reviewers have now
                    // reasoned about this branch and the first two deleted it
                    // in their heads; measure before believing either.
                    var startsAtLineBoundary = tailStart == 0
                    if tailStart > 0 {
                        stage = "seek to tailStart-1"
                        try handle.seek(toOffset: tailStart - 1)
                        stage = "read boundary byte"
                        if let probe = try handle.read(upToCount: 1), probe == Data([0x0A]) {
                            startsAtLineBoundary = true
                        }
                    }
                    stage = "seek to tailStart"
                    try handle.seek(toOffset: tailStart)
                    stage = "readToEnd"
                    let tailData = try handle.readToEnd() ?? Data()
                    let tailText = String(decoding: tailData, as: UTF8.self)
                    let tailLines = tailText.split(separator: "\n", omittingEmptySubsequences: true)
                    let start = startsAtLineBoundary ? 0 : 1
                    if start < tailLines.count {
                        // Reversed: the last relocated in the tail wins on first hit.
                        for line in tailLines[start...].reversed() {
                            guard line.contains("relocated"),
                                  let lineData = line.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                                  json["type"] as? String == "relocated",
                                  let value = json["relocatedCwd"] as? String, !value.isEmpty
                            else { continue }
                            lastRelocatedCwd = value
                            break
                        }
                    }
                }
            } catch {
                logger.error("extractMetadata: tail scan I/O failed at \(stage, privacy: .public) for \(path, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }

        let cwd = lastRelocatedCwd ?? firstCwd
        let title = aiTitle ?? firstUserMessage ?? "Untitled"
        return (title, cwd, isBackgroundScheduled, entrypoint?.hasPrefix("sdk-") == true)
    }
}
