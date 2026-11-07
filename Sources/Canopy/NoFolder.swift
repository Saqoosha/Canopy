import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "NoFolder")

/// Where a session runs when the user starts it without a folder. The CLI needs
/// one, so Canopy keeps a folder of its own, shared by Debug and Release.
enum NoFolder {
    static let displayName = "No folder"

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Canopy/no-folder", isDirectory: true)

    /// The folder's `CLAUDE.md`.
    static let instructions = """
        # No folder

        This is not a project. A session runs here when the user starts without a folder, so there is nothing in this folder to read or change.

        - For a question about earlier work, use the `canopy-bridge:find-session` skill. It searches past sessions on this Mac and the paired ones.
        - When the conversation turns into work on a project, say which folder it belongs in and suggest moving there.

        """

    /// By spelling first, because `GitWorktree.repoName` runs per row: only another
    /// folder of this name pays for `realpath`. A symlink under another name is not No folder.
    static func isNoFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent == directory.lastPathComponent else { return false }
        return standardized.path == directory.path
            || GitWorktree.realPath(of: url) == GitWorktree.realPath(of: directory)
    }

    /// Creates the folder, and writes `CLAUDE.md` only when its text differs.
    @discardableResult
    static func prepare() -> URL {
        let file = directory.appendingPathComponent("CLAUDE.md")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != instructions {
                try instructions.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Could not prepare the No folder directory: \(error.localizedDescription, privacy: .public)")
        }
        return directory
    }
}
