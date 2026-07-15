import Foundation
import Observation

@Observable
final class StatusBarData {
    var cliVersion: String = ""
    var model: String = ""
    var contextUsed: Int = 0
    var contextMax: Int = 0
    var maxOutputTokens: Int = 0
    var messageCount: Int = 0
    var gitBranch: String = ""
    var vcsType: VCSType = .unknown
    var remoteHost: String?

    // Compact boundary indicator
    var didCompact: Bool = false

    /// Subagent activity rows for the current turn (CLI-style task list,
    /// rendered by SubagentListView). Snapshot pushed from ShimProcess's
    /// SubagentTracker whenever it changes.
    var subagents: [SubagentInfo] = []

    /// Live width (in AppKit points) of the CC extension's chat-input
    /// column, measured from the webview via `InputWidthProbe`. `nil` until
    /// the probe reports its first value or when the target element can't
    /// be found. `SubagentListView` mirrors this width so its rows line up
    /// with the input area instead of sprawling edge-to-edge.
    ///
    /// `didSet` clamps any non-positive assignment back to `nil` — the
    /// message handler already filters, so this guards against future
    /// direct assignments that skip the pipeline. Non-triggering on
    /// initialisation is fine (default is already `nil`).
    var chatInputWidth: CGFloat? {
        didSet {
            if let w = chatInputWidth, w <= 0 {
                chatInputWidth = nil
            }
        }
    }

    enum VCSType { case unknown, git, jj }

    /// Effective context window matching CC extension's pie chart: contextWindow - maxOutputTokens - 13000.
    private static let compactionBuffer = 13_000
    var compactionWindow: Int {
        let effective = contextMax - maxOutputTokens - Self.compactionBuffer
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
        maxOutputTokens = 0
        messageCount = 0
        gitBranch = ""
        vcsType = .unknown
        didCompact = false
        remoteHost = nil
        subagents = []
        chatInputWidth = nil
    }

}
