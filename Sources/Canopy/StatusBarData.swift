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

    /// Which of the Claude Code CLI's thresholds the session has crossed.
    /// `.unknown` is NOT "fine" — it means the inputs can't produce a
    /// trustworthy threshold, so the meter must fall back to a cruder signal
    /// rather than imply headroom. See `contextLevel` and issue #110.
    enum ContextLevel { case unknown, ok, warn, compact, blocked }

    private static let compactionBuffer = 13_000
    private static let outputReserveCap = 20_000
    /// Equal to `outputReserveCap` by coincidence — an unrelated quantity
    /// (how far below the compact level the CLI starts warning). Do not merge
    /// the two constants.
    private static let warnOffset = 20_000
    private static let blockedHeadroom = 3_000

    /// The CLI's output reserve for this model — the cap is what #106 was
    /// about. Factored out because both `compactionWindow` and the `blocked`
    /// threshold need it, and they subtract different buffers from it.
    private var outputReserve: Int { min(maxOutputTokens, Self.outputReserveCap) }

    /// Whether the level offsets describe anything real. Two conditions, and
    /// they are NOT the same as `compactionWindow`'s fallback test — keep them
    /// separate:
    ///
    /// - `maxOutputTokens > 0`. Zero does not mean "this model reserves no
    ///   output", it means "we haven't been told yet" — reachable on launch,
    ///   because `contextMax` and `maxOutputTokens` restore from two
    ///   independent UserDefaults keys under separate `> 0` guards, and a
    ///   `result` whose `modelUsage` entry omits `maxOutputTokens` caches a
    ///   `0` (the `?? 0` in `ShimProcess.mainModelUsage`) that the restore
    ///   guard then skips, leaving the pair half-populated. Letting it through
    ///   would print a refusal threshold up to 20,000 tokens too high as
    ///   fact, which is exactly the confidently-wrong failure this level
    ///   exists to avoid. `compactionWindow` deliberately does NOT gate on
    ///   it, and the asymmetry is the point: the same error only shifts a
    ///   percentage slightly optimistic, which is a graph reading a little
    ///   wrong, whereas an absolute token count presented as the line where
    ///   requests start failing is simply a lie.
    /// - The compact arithmetic is positive, i.e. `compactionWindow` did not
    ///   fall back to raw `contextMax`.
    private var hasTrustedThresholds: Bool {
        maxOutputTokens > 0 && contextMax - outputReserve - Self.compactionBuffer > 0
    }

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
    /// - The CLI's warn and hard-block lines sit at other offsets; this is
    ///   the compact level only. `contextLevel` derives the other two.
    ///
    /// Falls back to the raw `contextMax` when the subtractions would go
    /// non-positive. Usually that is the pre-`result` state where `contextMax`
    /// is still 0 — `contextPct` then returns 0 through its own `window > 0`
    /// guard, and `StatusBarView` hides the meter entirely while
    /// `contextMax == 0`. It is also reachable with a POPULATED `contextMax`
    /// below ~33,000, where it reports a denominator wider than the real
    /// budget; the probe's `tiny` case pins that branch.
    var compactionWindow: Int {
        let effective = contextMax - outputReserve - Self.compactionBuffer
        return effective > 0 ? effective : contextMax
    }

    /// Percentage of `compactionWindow` consumed. **Deliberately unclamped**
    /// (issue #110): the old `min(100, …)` made the entire actionable band —
    /// the CLI's compact level crossed, then the next request refused 10,000
    /// tokens later — render as an identical flat 100%. Fixed-width bars must
    /// go through `barFillWidth(pct:track:minimum:)` rather than scaling this
    /// directly.
    ///
    /// Not floored at 0 either. A negative percentage can only come from a
    /// negative `contextUsed`, which the CLI cannot produce; if it ever
    /// appears, "-12%" is unmistakably a bug while a floored "0%" is
    /// indistinguishable from a fresh session. Failing visibly beats
    /// rendering a plausible number.
    var contextPct: Int {
        let window = compactionWindow
        guard window > 0 else { return 0 }
        return contextUsed * 100 / window
    }

    /// Token count at which the CLI refuses the next request outright, or
    /// `nil` when `hasTrustedThresholds` is false.
    ///
    /// The refusal guard differs from the compact level on TWO axes, and the
    /// second one is the interesting one:
    /// 1. It subtracts 3,000 from the budget WITHOUT the 13,000 compaction
    ///    buffer, so it lands 10,000 ABOVE `compactionWindow`, not below.
    /// 2. It is computed from the model's RAW context window, while the
    ///    compact level is computed from the CLAMPED one. `modelUsage` reports
    ///    the raw window, so **this threshold is not subject to the clamp
    ///    blindness documented on `compactionWindow`** — under an active clamp
    ///    the CLI's own gap widens, but this number stays right.
    ///
    /// That makes `blocked` the most trustworthy thing this type computes.
    /// It is also unaffected by whether auto-compact is enabled.
    ///
    /// Two caveats it does share with `compactionWindow`, both from the same
    /// `outputReserve`: `CLAUDE_CODE_MAX_OUTPUT_TOKENS` below the cap shrinks
    /// the CLI's reserve while `modelUsage` keeps reporting the model default
    /// (so this reads low — the conservative direction), and an env override
    /// exists that replaces the CLI's refusal line outright, which nothing
    /// here models. Verified against CLI 2.1.217; re-derive from the literals
    /// rather than trusting this comment.
    var blockedThreshold: Int? {
        guard hasTrustedThresholds else { return nil }
        return contextMax - outputReserve - Self.blockedHeadroom
    }

    /// Which CLI threshold the session has crossed.
    ///
    /// `blocked` is the level worth acting on: it is the hard request-refusal
    /// guard, it holds regardless of compaction settings, and (per
    /// `blockedThreshold`) it is clamp-immune. The other two are softer:
    /// - `compact` assumes auto-compact is ENABLED. With it disabled the CLI
    ///   never reports a compact level at all, so this over-reports.
    /// - `warn` uses the compact level as its base, which is also only the
    ///   enabled-case behaviour; disabled, the CLI's warn line sits 13,000
    ///   higher. Canopy can't observe the setting, so both assume the default.
    ///
    /// Returns `.unknown` — NOT `.ok` — when the thresholds aren't
    /// trustworthy. Those are different claims, and collapsing them would be
    /// a regression rather than a safe default: the pre-#110 meter turned red
    /// at 80% of its denominator, so folding "can't tell" into "fine" would
    /// take an over-budget small-window session from a red 100% to a calm
    /// grey 150%. `tint(for:pct:)` maps `.unknown` back onto the raw
    /// percentage instead — the old crude heuristic, used honestly as a
    /// fallback rather than as the primary signal.
    var contextLevel: ContextLevel {
        guard let blocked = blockedThreshold else { return .unknown }
        let compact = compactionWindow
        if contextUsed >= blocked { return .blocked }
        if contextUsed >= compact { return .compact }
        // A window narrower than the warn offset puts the warn line at or
        // below zero. The CLI has no such guard and genuinely reports `warn`
        // from zero usage there — but claiming `.ok` all the way to 99% of
        // the compact level would be the calm-but-wrong reading this whole
        // change exists to remove. Report `.unknown` instead: the window is
        // too narrow for the threshold model, and the percentage heuristic
        // still turns the meter red before it matters.
        let warnLine = compact - Self.warnOffset
        guard warnLine > 0 else { return .unknown }
        if contextUsed >= warnLine { return .warn }
        return .ok
    }

    /// How a level should read, without the view layer's `Color` vocabulary —
    /// so the mapping is probe-reachable. `levelColor` is a thin adapter.
    ///
    /// This is deliberately not left in the view: "`.unknown` at 150% must be
    /// ALERT, not calm" is the whole point of `.unknown` existing, and a
    /// future simplification of the view's switch to `case .unknown: .secondary`
    /// would restore the regression with every probe still green.
    enum ContextTint { case calm, warn, alert }

    /// `.unknown` falls back to the crude percentage cutoffs the real levels
    /// replaced. That is the honest reading: with no trustworthy threshold,
    /// the pre-#110 heuristic is better than calm grey — it is what kept an
    /// over-budget session red before this feature existed.
    static func tint(for level: ContextLevel, pct: Int) -> ContextTint {
        switch level {
        case .unknown: pct >= 80 ? .alert : (pct >= 50 ? .warn : .calm)
        case .ok: .calm
        case .warn: .warn
        case .compact, .blocked: .alert
        }
    }

    /// Fill width for a fixed-width meter track. `contextPct` is unclamped by
    /// design, so the clamp lives here — in one probe-reachable place — rather
    /// than in a doc-comment obligation every future bar has to remember.
    /// Mirrors `SidebarAccountSection`'s pattern of clamping at the boundary.
    static func barFillWidth(pct: Int, track: CGFloat, minimum: CGFloat) -> CGFloat {
        let fill = track * CGFloat(min(pct, 100)) / 100
        // `minimum` is bounded by `track` too: a sliver of usage must still be
        // visible, but never wider than the track it sits in.
        return fill > 0 ? min(track, max(minimum, fill)) : 0
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
