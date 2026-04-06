import Foundation
import Observation

@Observable
final class StatusBarData {
    var cliVersion: String = ""
    var model: String = ""
    var contextUsed: Int = 0
    var contextMax: Int = 0
    var messageCount: Int = 0
    var gitBranch: String = ""
    var vcsType: VCSType = .unknown
    var remoteHost: String?

    // Compact boundary indicator
    var didCompact: Bool = false

    enum VCSType { case unknown, git, jj }

    /// Effective context window for compaction purposes (matches CC's auto-compact: effectiveWindow = contextMax - 8000).
    private static let compactionBuffer = 8_000
    var compactionWindow: Int {
        let effective = contextMax - Self.compactionBuffer
        return effective > 0 ? effective : contextMax
    }

    var contextPct: Int {
        let window = compactionWindow
        guard window > 0 else { return 0 }
        return min(100, contextUsed * 100 / window)
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func resetContext() {
        contextUsed = 0
        didCompact = true
    }

    func clearCompactIndicator() {
        didCompact = false
    }

    /// Reset all data for a new session.
    func resetAll() {
        cliVersion = ""
        model = ""
        contextUsed = 0
        contextMax = 0
        messageCount = 0
        gitBranch = ""
        vcsType = .unknown
        didCompact = false
        remoteHost = nil
    }

}
