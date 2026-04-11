import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SessionHistory")

struct SessionEntry: Identifiable {
    let id: String
    let title: String
    let timestamp: Date
    let projectDirectory: URL

    var projectName: String { projectDirectory.lastPathComponent }
}

enum ClaudeSessionHistory {
    private static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Maximum number of sessions to parse (sorted by most recent first).
    private static let maxSessionsToParse = 50

    /// Encode a directory path to the Claude project folder name.
    /// Matches Claude CLI encoding: every non-alphanumeric character (except `_`)
    /// inside a component becomes `-`. Components are joined with `-` and the result
    /// is prefixed with `-` for the leading `/`. So `/.config` → `--config` and
    /// `/Users/hiko/Canopy Companion` → `-Users-hiko-Canopy-Companion`.
    static func encodePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let mapped = components.map { component -> String in
            String(component.map { ch -> Character in
                (ch.isLetter || ch.isNumber || ch == "_") ? ch : "-"
            })
        }
        return "-" + mapped.joined(separator: "-")
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
    static func loadSessions(for directory: URL) -> [SessionEntry] {
        let encoded = encodePath(directory.path)
        let projectDir = claudeDir.appendingPathComponent(encoded)
        return loadSessionsFromDir(projectDir, projectDirectory: directory)
    }

    /// Load sessions across all projects, sorted by most recent.
    /// Collects file metadata first (no file reads), sorts by date,
    /// then parses only the top N candidates for title extraction.
    static func loadAllSessions() -> [SessionEntry] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [] }

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir.path) else { return [] }

        // Phase 1: collect all JSONL file metadata (no content reads)
        var candidates: [(path: String, modDate: Date, sessionId: String, projectEncoded: String)] = []

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
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date
                else { continue }

                candidates.append((filePath, modDate, sessionId, projectEncoded))
            }
        }

        // Phase 2: sort by date, take top N
        candidates.sort { $0.modDate > $1.modDate }
        let topCandidates = candidates.prefix(maxSessionsToParse)

        // Phase 3: resolve cwd and title from JSONL metadata (single read per file).
        // Prefer the `cwd` field written by the CLI over lossy folder-name decoding —
        // the encoded form collapses spaces/dots into `-` so directories like
        // "Canopy Companion" can't be recovered by walking the filesystem.
        // Skip sessions whose project directory no longer exists on disk.
        var entries: [SessionEntry] = []
        for candidate in topCandidates {
            let metadata = extractMetadata(fromPath: candidate.path)
            let projectPath = metadata.cwd ?? decodePath(candidate.projectEncoded)
            guard fm.fileExists(atPath: projectPath) else { continue }
            let projectDirectory = URL(fileURLWithPath: projectPath)
            let title = SessionTitleStore.title(forSessionId: candidate.sessionId)
                ?? metadata.title

            entries.append(SessionEntry(
                id: candidate.sessionId,
                title: title,
                timestamp: candidate.modDate,
                projectDirectory: projectDirectory
            ))
        }

        return entries
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

                let title = SessionTitleStore.title(forSessionId: sessionId)
                    ?? extractTitle(from: file)
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
        let encoded = encodePath(directory.path)
        let filePath = claudeDir
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(sessionId).jsonl").path
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return 0 }
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

    /// Extract session title: prefer `ai-title` entry, fall back to first user message.
    private static func extractTitle(from file: URL) -> String {
        extractMetadata(fromPath: file.path).title
    }

    /// Read up to 128KB to find `ai-title` (generated by Claude Code, usually within the first
    /// few lines but may be preceded by large base64 image data), the first user message, and
    /// the `cwd` recorded on any entry. Returns both so callers can avoid lossy path decoding.
    private static func extractMetadata(fromPath path: String) -> (title: String, cwd: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ("Untitled", nil)
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 131_072)
        guard let text = String(data: data, encoding: .utf8) else { return ("Untitled", nil) }

        var aiTitle: String?
        var firstUserMessage: String?
        var cwd: String?

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if cwd == nil, let value = json["cwd"] as? String, !value.isEmpty {
                cwd = value
            }

            guard let type = json["type"] as? String else { continue }

            if aiTitle == nil, type == "ai-title",
               let value = json["aiTitle"] as? String, !value.isEmpty
            {
                aiTitle = value
            }

            if firstUserMessage == nil, type == "user",
               let message = json["message"] as? [String: Any]
            {
                if let content = message["content"] as? String, !content.isEmpty {
                    firstUserMessage = String(content.prefix(100))
                } else if let contentArr = message["content"] as? [[String: Any]] {
                    let joined = contentArr.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !joined.isEmpty { firstUserMessage = String(joined.prefix(100)) }
                }
            }

            if aiTitle != nil, cwd != nil, firstUserMessage != nil { break }
        }

        let title = aiTitle ?? firstUserMessage ?? "Untitled"
        return (title, cwd)
    }
}
