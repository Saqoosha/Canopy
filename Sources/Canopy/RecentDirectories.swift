import Foundation

enum RecentDirectories {
    private static let key = "recentDirectories"
    private static let maxEntries = 20

    static func load() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return paths.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { !GitWorktree.isManagedWorktree($0) }
    }

    static func add(_ url: URL) {
        // Worktrees carry no project context in their folder name ("work-…")
        // and are re-openable from the sidebar's closed-session row, so keep
        // them out of Recents entirely. Callers don't need to gate.
        guard !GitWorktree.isManagedWorktree(url) else { return }
        var dirs = load()
        dirs.removeAll { $0 == url }
        dirs.insert(url, at: 0)
        if dirs.count > maxEntries { dirs = Array(dirs.prefix(maxEntries)) }
        UserDefaults.standard.set(dirs.map(\.path), forKey: key)
    }

    static func remove(_ url: URL) {
        var dirs = load()
        dirs.removeAll { $0 == url }
        UserDefaults.standard.set(dirs.map(\.path), forKey: key)
    }
}
