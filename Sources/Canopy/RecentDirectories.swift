import Foundation

enum RecentDirectories {
    private static let key = "recentDirectories"
    private static let maxEntries = 20

    static func load() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return paths.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            // Also filter on read: worktree entries persisted by pre-guard
            // builds are masked (not physically scrubbed) here, and any
            // subsequent `add(_:)` rewrites the filtered list back to disk.
            .filter { !GitWorktree.isManagedWorktree($0) }
            // Collapse duplicates persisted by builds that compared with
            // `URL ==` (see `add`); keep the first, i.e. most recent.
            .reduce(into: [URL]()) { kept, url in
                if !kept.contains(where: { $0.path == url.path }) { kept.append(url) }
            }
    }

    static func add(_ url: URL) {
        // Worktree folder names are branch-derived and carry no project
        // context, so the launcher dropdown would show meaningless entries.
        // Sessions inside a worktree remain reachable via the sidebar's
        // Recents/closed rows, so nothing is lost by skipping the write.
        // Callers don't need to gate.
        guard !GitWorktree.isManagedWorktree(url) else { return }
        var dirs = load()
        // Compare by path, not `URL ==`: that compares absoluteString, and
        // `URL(fileURLWithPath:)` adds a trailing slash for an existing
        // directory while `isDirectory: false` does not — so the same folder
        // compared unequal, was re-inserted, and `.path` stored it identically.
        dirs.removeAll { $0.path == url.path }
        dirs.insert(url, at: 0)
        if dirs.count > maxEntries { dirs = Array(dirs.prefix(maxEntries)) }
        UserDefaults.standard.set(dirs.map(\.path), forKey: key)
    }

    static func remove(_ url: URL) {
        var dirs = load()
        dirs.removeAll { $0.path == url.path }
        UserDefaults.standard.set(dirs.map(\.path), forKey: key)
    }
}
