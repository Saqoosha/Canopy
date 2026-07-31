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

    /// Transient status-bar message (e.g. "Maximum 5 panes"). Cleared
    /// automatically by `showHint(_:forSeconds:)` after the timeout.
    var transientHint: String? = nil
    private var hintClearTask: Task<Void, Never>?

    enum VCSType { case unknown, git, jj }

    private static let compactionBuffer = 13_000
    private static let outputReserveCap = 20_000

    /// Effective context window, matching the `compact` level the Claude Code
    /// CLI's own context meter counts against:
    /// `contextMax - min(maxOutputTokens, 20000) - 13000`.
    ///
    /// The CLI caps the output reserve at 20,000 for every model, then
    /// subtracts a 13,000 compaction buffer. Verified against CLI 2.1.217 by
    /// reading the shipped bundle — the binary embeds readable minified JS, so
    /// use `grep -a` (plain `grep` treats it as binary and prints nothing).
    /// The symbol names change every release, so they are not cited here;
    /// re-derive from the 20000 / 13000 literals if this needs rechecking.
    ///
    /// The CC extension's pie subtracts the FULL `maxOutputTokens` instead, so
    /// for models with a bigger output budget (Opus 5: 64,000) it reads 100%
    /// about 44,000 tokens before anything actually happens. We deliberately
    /// diverge from the extension's pie — the meter should track the CLI. See
    /// issue #106.
    ///
    /// The claim is about the DENOMINATOR, and it is the CLI's *meter* level —
    /// NOT a promise about the moment compaction happens. Cases we don't
    /// model, each making the meter approximate:
    /// - On a local run with an unclamped (default) window the CLI skips its
    ///   proactive check entirely. What replaces it depends on a server gate:
    ///   with precomputed compaction ON it compacts off a threshold roughly a
    ///   fifth below this line (the fraction is itself server-tunable and is
    ///   taken off the pre-buffer window, so the gap against this line is
    ///   smaller on smaller windows), landing well before the meter reads
    ///   100%; with it OFF compaction is reactive and lands after.
    /// - The CLI can clamp its window below the model's context window
    ///   (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, the `autoCompactWindow` setting,
    ///   server-pushed clientdata, an experiment gate, or a per-model
    ///   default) — then it compacts earlier than we show. `modelUsage`
    ///   reports the RAW window, so `contextMax` is structurally blind to
    ///   every one of these.
    /// - With auto-compact disabled the CLI drops the 13,000 subtraction, so
    ///   the meter reads pessimistically by that much.
    /// - `CLAUDE_CODE_MAX_OUTPUT_TOKENS` below 20,000 shrinks the CLI's
    ///   reserve, while `maxOutputTokens` here comes from the `result` event's
    ///   `modelUsage`, which reports the model default.
    /// - The CLI's warn and hard-block lines sit at other offsets; this
    ///   tracks the compact level only.
    ///
    /// Falls back to the raw `contextMax` when the subtractions would go
    /// non-positive. Usually that is the pre-`result` state where `contextMax`
    /// is still 0 — `contextPct` then returns 0 through its own `window > 0`
    /// guard, and `StatusBarView` hides the meter entirely while
    /// `contextMax == 0`. It is also reachable with a POPULATED `contextMax`
    /// below ~33,000, where it reports a denominator wider than the real
    /// budget; the probe's `tiny` case pins that branch.
    var compactionWindow: Int {
        let reserve = min(maxOutputTokens, Self.outputReserveCap)
        let effective = contextMax - reserve - Self.compactionBuffer
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
        hintClearTask?.cancel()
        hintClearTask = nil
        transientHint = nil
    }

    /// Post a self-clearing status-bar hint. Cancels any in-flight clear
    /// so rapid re-fires restart the timer.
    @MainActor
    func showHint(_ text: String, forSeconds: TimeInterval = 1.5) {
        transientHint = text
        hintClearTask?.cancel()
        hintClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(forSeconds))
            if !Task.isCancelled {
                await MainActor.run { self?.transientHint = nil }
            }
        }
    }

}
