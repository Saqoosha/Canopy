import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "SessionHistory")

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

    /// Encode a directory path to the Claude project folder name.
    /// Claude CLI replaces both `/` and `.` with `-`.
    /// `/Users/hiko/.config/foo` → `-Users-hiko--config-foo`
    static func encodePath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Load sessions for a specific working directory.
    static func loadSessions(for directory: URL) -> [SessionEntry] {
        let encoded = encodePath(directory.path)
        let projectDir = claudeDir.appendingPathComponent(encoded)

        return loadSessionsFromDir(projectDir, projectDirectory: directory)
    }

    /// Load sessions across all projects by reading cwd from JSONL metadata.
    static func loadAllSessions() -> [SessionEntry] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [] }

        do {
            let projects = try FileManager.default.contentsOfDirectory(
                at: claudeDir, includingPropertiesForKeys: nil
            )
            var all: [SessionEntry] = []
            for projectDir in projects {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                // Read cwd from the first JSONL file instead of decoding folder name
                guard let realPath = extractCwd(from: projectDir) else { continue }
                let dir = URL(fileURLWithPath: realPath)
                all.append(contentsOf: loadSessionsFromDir(projectDir, projectDirectory: dir))
            }
            return all.sorted { $0.timestamp > $1.timestamp }
        } catch {
            logger.error("Failed to enumerate projects: \(error.localizedDescription, privacy: .public)")
            return []
        }
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

                let title = extractTitle(from: file)
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

    /// Read the `cwd` field from the first message in any JSONL file in the project directory.
    private static func extractCwd(from projectDir: URL) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil
        ) else { return nil }

        let jsonlFile = contents.first { $0.pathExtension == "jsonl" }
        guard let file = jsonlFile,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = json["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }

    /// Extract the first user message (up to 8KB) from a session JSONL file as the title,
    /// truncated to 100 characters.
    private static func extractTitle(from file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            logger.warning("Could not open session file for title: \(file.lastPathComponent, privacy: .public)")
            return "Untitled"
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let text = String(data: data, encoding: .utf8) else { return "Untitled" }

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if type == "user",
               let message = json["message"] as? [String: Any]
            {
                if let content = message["content"] as? String {
                    return String(content.prefix(100))
                }
                if let contentArr = message["content"] as? [[String: Any]] {
                    let text = contentArr.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !text.isEmpty { return String(text.prefix(100)) }
                }
            }
        }
        return "Untitled"
    }
}
