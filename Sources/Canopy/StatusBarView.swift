import SwiftUI

struct StatusBarView: View {
    let data: StatusBarData
    @State private var showPopover: Bool = false

    /// Per-pane width thresholds (from `data.chatInputWidth`) at which
    /// status-bar items collapse. Defaults are educated first guesses;
    /// retune after a manual narrow-pane smoke test.
    fileprivate enum CollapseThreshold {
        /// Below this, drop the session-usage counter (message count).
        static let dropSessionUsage: CGFloat = 620
        /// Below this, collapse branch to icon-only with tooltip.
        static let branchIcon: CGFloat = 500
        /// Below this, drop the numeric "132K/923K" and keep just the bar + %.
        static let dropContextNumeric: CGFloat = 440
        /// Below this, show only the model badge + a "…" popover with all items.
        static let popoverFallback: CGFloat = 300
    }

    var body: some View {
        // TimelineView ticks every 60s so any countdown labels stay fresh.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            statusBar(now: context.date)
        }
    }

    // MARK: - Main layout

    @ViewBuilder
    private func statusBar(now _: Date) -> some View {
        let w = data.chatInputWidth ?? .infinity  // no probe yet → assume wide
        // Compute what's visible up front so each leading separator can
        // check "was anything actually rendered to my left?" instead of
        // trusting a hard-coded predecessor. Fixes two related bugs
        // (double separators when e.g. remote is present but model is
        // empty, and orphan leading separator when model is empty and
        // branch is the first visible item).
        let hasRemote = data.remoteHost != nil
        let hasModel = !data.model.isEmpty
        let hasBranch = !data.gitBranch.isEmpty
        let hasContext = data.contextMax > 0
        let hasMessages = w >= CollapseThreshold.dropSessionUsage && data.messageCount > 0
        ZStack {
            Group {
                if w < CollapseThreshold.popoverFallback {
                    popoverBar
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        // Remote host — always shown when present (not in collapse priority).
                        if let remote = data.remoteHost {
                            pill(remote, icon: "network", color: .orange)
                                .help("SSH remote: \(remote)")
                        }

                        // Model (extension version moved to sidebar footer).
                        if hasModel {
                            if hasRemote { separator }
                            modelBadgeBlock
                        }

                        // VCS branch
                        if hasBranch {
                            if hasRemote || hasModel { separator }
                            if w >= CollapseThreshold.branchIcon {
                                branchPill
                            } else {
                                branchIconOnly
                            }
                        }

                        // Context usage — numeric + bar share a single HStack + tooltip
                        // to preserve the original 5pt spacing between numeric label
                        // and bar, and so hovering the numeric label also surfaces
                        // contextTooltip() (not just the bar).
                        if hasContext {
                            if hasRemote || hasModel || hasBranch { separator }
                            HStack(spacing: 5) {
                                if w >= CollapseThreshold.dropContextNumeric {
                                    contextNumericLabel
                                }
                                contextBar
                            }
                            .help(contextTooltip())
                        }

                        // Session usage (message count)
                        if hasMessages {
                            if hasRemote || hasModel || hasBranch || hasContext { separator }
                            sessionUsageBadge
                        }

                        Spacer()
                    }
                }
            }
            .opacity(data.transientHint == nil ? 1 : 0)

            if let hint = data.transientHint {
                HStack {
                    Spacer(minLength: 0)
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.trailing, 12)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: data.transientHint)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background(.white)
    }

    // MARK: - Popover fallback

    private var popoverBar: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            modelBadgeBlock
            Button { showPopover.toggle() } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .help("More status")
            .onDisappear { showPopover = false }
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if let remote = data.remoteHost {
                        pill(remote, icon: "network", color: .orange)
                            .help("SSH remote: \(remote)")
                    }
                    if !data.gitBranch.isEmpty { branchPill }
                    if data.contextMax > 0 {
                        HStack(spacing: 5) {
                            contextNumericLabel
                            contextBar
                        }
                        .help(contextTooltip())
                    }
                    if data.messageCount > 0 { sessionUsageBadge }
                }
                .padding(12)
            }
            Spacer()
        }
    }

    // MARK: - Extracted blocks (shared by full bar + popover)

    @ViewBuilder
    private var modelBadgeBlock: some View {
        if !data.model.isEmpty {
            pill(shortModelName(data.model), color: .purple)
                .help(data.model)
        }
    }

    private var branchPill: some View {
        let vcsEmoji = data.vcsType == .jj ? "🥋" : "🌿"
        return pill("\(vcsEmoji)\u{2009}\(data.gitBranch)", color: .green)
            .help("Branch: \(data.gitBranch)")
    }

    private var branchIconOnly: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 10))
            .foregroundStyle(.green)
            .help("Branch: \(data.gitBranch)")
    }

    private var contextBar: some View {
        let level = data.contextLevel
        let pct = data.contextPct
        return HStack(spacing: 5) {
            thinBar(pct: pct, level: level)
            // `blocked` is the only state where the NEXT action fails, and
            // `compact` is already red — so weight alone is too weak a channel
            // to carry the distinction (at a 1M window the two differ by one
            // percentage point). It gets a glyph as well.
            Text("\(pct)%")
                .foregroundStyle(levelColor(level, pct: pct))
                .fontWeight(level == .blocked ? .bold : .regular)
                .monospacedDigit()
                // Crossing 100 adds a digit and the weight switch changes
                // metrics; the context block sits between two Spacers, so
                // either would shift the whole bar without a width floor.
                .frame(minWidth: 30, alignment: .trailing)
            // One reserved slot, always laid out. Showing/hiding a glyph at
            // the compact→blocked boundary would shift the whole bar at the
            // one transition that matters most, undoing the frame above.
            // `.unknown` gets its own mark once the percentage is high enough
            // to look alarming, so an orange bar can't be mistaken for a real
            // warn level.
            Group {
                if level == .blocked {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Context limit reached")
                } else if level == .unknown, pct >= 50 {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(levelColor(level, pct: pct))
                        .accessibilityLabel("Context thresholds unavailable")
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9))
            .frame(width: 10)
            if data.didCompact {
                Text("↻")
                    .foregroundStyle(.blue)
            }
        }
        .help(contextTooltip())
    }

    private var contextNumericLabel: some View {
        Text("\(data.formatTokens(data.contextUsed))/\(data.formatTokens(data.compactionWindow))")
    }

    private var sessionUsageBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 8))
            Text("\(data.messageCount)")
        }
        .foregroundStyle(.tertiary)
        .help("Messages in session: \(Self.numberFormatter.string(from: NSNumber(value: data.messageCount)) ?? "\(data.messageCount)")")
    }

    // MARK: - Components

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 8)
    }

    private func pill(_ text: String, icon: String? = nil, color: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func thinBar(pct: Int, level: StatusBarData.ContextLevel, width: CGFloat = 40) -> some View {
        let barHeight: CGFloat = 4
        // Clamping lives in `barFillWidth` so it is probe-reachable — this
        // view isn't. `contextPct` is unclamped by design (issue #110), and an
        // unclamped fill would overrun the track and widen the status bar.
        let fill = StatusBarData.barFillWidth(pct: pct, track: width, minimum: barHeight)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: width, height: barHeight)
            if fill > 0 {
                Capsule()
                    .fill(levelColor(level, pct: pct))
                    .frame(width: fill, height: barHeight)
            }
        }
    }

    // MARK: - Helpers

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func contextTooltip() -> String {
        let used = Self.numberFormatter.string(from: NSNumber(value: data.contextUsed)) ?? "\(data.contextUsed)"
        let window = Self.numberFormatter.string(from: NSNumber(value: data.compactionWindow)) ?? "\(data.compactionWindow)"
        let maxTokens = Self.numberFormatter.string(from: NSNumber(value: data.contextMax)) ?? "\(data.contextMax)"
        var lines = [
            "Context: \(used) / \(window) tokens (\(data.contextPct)%)",
            "Maximum window: \(maxTokens) tokens",
        ]
        // Name the state in words. The percentage alone can't say whether
        // 101% means "auto-compact is due" or "the next request is refused".
        // Wording tracks the CLI's *meter level*, not the moment compaction
        // runs — `compactionWindow`'s doc lists why those differ.
        switch data.contextLevel {
        case .unknown:
            lines.append("Thresholds unavailable until the first response completes — the real budget may be narrower than shown")
        case .ok:
            break
        case .warn:
            lines.append("Approaching the CLI's compact level")
        case .compact:
            lines.append("Past the CLI's compact level")
        case .blocked:
            lines.append("Over the limit — the next request will be refused unless the context is compacted first")
        }
        // Only shown past a level, deliberately. An earlier revision showed it
        // whenever it was known, which surfaced a confidently wrong absolute
        // number in the one state it is most wrong: `contextMax` is the widest
        // window across every model in the session (issue #108), so a small
        // main model with a large-window subagent reads `.ok` at 19% while
        // this line would claim a refusal point five times too high. Gating on
        // the level keeps it hidden exactly there.
        if data.contextLevel != .ok, data.contextLevel != .unknown,
           let blocked = data.blockedThreshold
        {
            let n = Self.numberFormatter.string(from: NSNumber(value: blocked)) ?? "\(blocked)"
            lines.append("Requests refused at: \(n) tokens")
        }
        if data.didCompact {
            lines.append("Recently compacted")
        }
        return lines.joined(separator: "\n")
    }

    /// Thin adapter over `StatusBarData.tint(for:pct:)` — the decision lives
    /// on the model so the probe can reach it; only the `Color` vocabulary is
    /// the view's. Do not reintroduce a switch over `ContextLevel` here.
    private func levelColor(_ level: StatusBarData.ContextLevel, pct: Int) -> Color {
        switch StatusBarData.tint(for: level, pct: pct) {
        case .calm: .secondary
        case .warn: .orange
        case .alert: .red
        }
    }

    private func shortModelName(_ model: String) -> String {
        // "claude-sonnet-4-5-20250514" → "Sonnet 4.5"
        // "claude-opus-4-6" → "Opus 4.6"
        // "claude-opus-4-7[1m]" → "Opus 4.7 (1M)"
        let (base, variantSuffix) = ModelNameFormatter.splitVariant(model)
        let lower = base.lowercased()
        for (family, label) in [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")] {
            if lower.contains(family) {
                if let v = extractVersion(from: lower, family: family) { return "\(label) \(v)\(variantSuffix)" }
                return "\(label)\(variantSuffix)"
            }
        }
        // Unknown family: preserve variant suffix so raw "[1m]" doesn't leak through.
        return base + variantSuffix
    }

    private func extractVersion(from model: String, family: String) -> String? {
        // "claude-sonnet-4-5-20250514" → after "sonnet-" grab "4-5", convert to "4.5"
        guard let range = model.range(of: "\(family)-") else { return nil }
        let after = model[range.upperBound...]
        var digits: [String] = []
        for part in after.split(separator: "-") {
            if part.allSatisfy(\.isNumber), part.count <= 2 { digits.append(String(part)) }
            else { break }
        }
        return digits.isEmpty ? nil : digits.joined(separator: ".")
    }

}

#if DEBUG
private let _validateCollapseThresholds: Void = {
    assert(StatusBarView.CollapseThreshold.dropSessionUsage
         > StatusBarView.CollapseThreshold.branchIcon
         && StatusBarView.CollapseThreshold.branchIcon
         > StatusBarView.CollapseThreshold.dropContextNumeric
         && StatusBarView.CollapseThreshold.dropContextNumeric
         > StatusBarView.CollapseThreshold.popoverFallback)
}()
#endif
