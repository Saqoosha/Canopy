import Foundation
import os.log

enum GitWorktree {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "GitWorktree")

    /// All Canopy-created worktrees live here, grouped by repository name —
    /// hidden away from the projects tree so the repo's parent folder stays
    /// clean (same shape as Cursor's ~/.cursor/worktrees).
    static let worktreesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/worktrees", isDirectory: true)

    /// Display label for a session directory. Recognized worktree layouts
    /// (managed root + `<repo>-worktrees` sibling) surface the repository the
    /// worktree belongs to ("Canopy · fix-foo" — the second part is the
    /// worktree FOLDER name, i.e. the branch with `/` flattened to `-`).
    /// Worktrees anywhere else fall back to the plain folder name by design.
    static func projectDisplayName(for dir: URL) -> String {
        // Lexical normalization ("..", ".") so cwd-derived paths still match
        // the layout checks. Symlink resolution is deliberately skipped — this
        // runs per sidebar-row render, and a miss only degrades to the plain
        // folder name.
        let standardized = dir.standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent()
        // Managed layout: ~/.claude/worktrees/<repo>/<branch>
        if parent.deletingLastPathComponent().path == worktreesRoot.path {
            return "\(parent.lastPathComponent) · \(name)"
        }
        // Sibling layout (<repoParent>/<repo>-worktrees/<branch>): used by
        // pre-release Canopy builds and common external tooling conventions.
        let parentName = parent.lastPathComponent
        let suffix = "-worktrees"
        if parentName.hasSuffix(suffix), parentName.count > suffix.count {
            return "\(String(parentName.dropLast(suffix.count))) · \(name)"
        }
        return name
    }

    static func isGitRepo(_ dir: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let gitPath = dir.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return false
        }
        return true
    }

    static func sanitizeBranchName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: " ", with: "-")

        let invalidScalars = CharacterSet(charactersIn: "~^:?*[]\\").union(.whitespacesAndNewlines)
        s = String(s.unicodeScalars.filter { !invalidScalars.contains($0) })

        while s.contains("//") {
            s = s.replacingOccurrences(of: "//", with: "/")
        }

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/."))

        if s.hasSuffix(".lock") {
            s = String(s.dropLast(".lock".count))
        }

        return s
    }

    static func suggestedBranchName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "work-\(formatter.string(from: now))"
    }

    /// Set when the watchdog terminated the process, so the error path can
    /// distinguish a timeout from a normal git failure.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    static func createWorktree(repo: URL, branch: String, timeout: TimeInterval = 120) throws -> URL {
        let repoName = repo.lastPathComponent
        let branchComponent = branch.replacingOccurrences(of: "/", with: "-")
        let worktreesParent = worktreesRoot.appendingPathComponent(repoName, isDirectory: true)
        let worktreeURL = worktreesParent.appendingPathComponent(branchComponent, isDirectory: true)

        try FileManager.default.createDirectory(at: worktreesParent, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repo.path, "worktree", "add", "-b", branch, worktreeURL.path]

        // Only stderr matters for diagnostics, and reading a single stream to
        // EOF cannot deadlock. Draining two pipes sequentially can: blocking
        // on stdout's EOF while the child fills the 64KB stderr buffer stalls
        // both processes. Commands that need stdout must drain concurrently
        // (see CloneRepoSheet's DispatchGroup pattern).
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        // Checkout can block forever on git-lfs credential prompts, askpass,
        // or stuck hooks — kill and surface instead of hanging the launcher.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem { [weak proc] in
            timedOut.set()
            proc?.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        try proc.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        if timedOut.value {
            let message = "git worktree add timed out after \(Int(timeout))s — check git hooks or LFS credential prompts"
            logger.error("\(message, privacy: .public)")
            throw NSError(domain: "GitWorktree", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let status = proc.terminationStatus
        if status != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (stderr?.isEmpty == false) ? stderr! : "git worktree add failed (exit \(status))"
            logger.error("worktree add failed (status \(status)): \(message, privacy: .public)")
            throw NSError(
                domain: "GitWorktree",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        logger.info("Created worktree at \(worktreeURL.path, privacy: .public) on branch \(branch, privacy: .public)")
        return worktreeURL
    }
}
