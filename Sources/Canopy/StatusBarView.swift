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
        /// Below this, collapse CLI version to icon-only with tooltip.
        static let cliVersionIcon: CGFloat = 560
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
                            separator
                        }

                        // Model + Version (model never dropped)
                        HStack(spacing: 5) {
                            modelBadgeBlock
                            if w >= CollapseThreshold.cliVersionIcon {
                                cliVersionText
                            } else if !data.cliVersion.isEmpty {
                                cliVersionIcon
                            }
                        }

                        // VCS branch
                        if !data.gitBranch.isEmpty {
                            separator
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
                        if data.contextMax > 0 {
                            separator
                            HStack(spacing: 5) {
                                if w >= CollapseThreshold.dropContextNumeric {
                                    contextNumericLabel
                                }
                                contextBar
                            }
                            .help(contextTooltip())
                        }

                        // Session usage (message count)
                        if w >= CollapseThreshold.dropSessionUsage, data.messageCount > 0 {
                            separator
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
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if let remote = data.remoteHost {
                        pill(remote, icon: "network", color: .orange)
                            .help("SSH remote: \(remote)")
                    }
                    cliVersionText
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

    @ViewBuilder
    private var cliVersionText: some View {
        if !data.cliVersion.isEmpty {
            Text("v\(data.cliVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var cliVersionIcon: some View {
        Image(systemName: "terminal")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .help("v\(data.cliVersion)")
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
        HStack(spacing: 5) {
            thinBar(pct: data.contextPct)
            Text("\(data.contextPct)%")
                .foregroundStyle(pctColor(data.contextPct))
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

    private func thinBar(pct: Int, width: CGFloat = 40) -> some View {
        let barHeight: CGFloat = 4
        let fill = width * CGFloat(pct) / 100
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: width, height: barHeight)
            if fill > 0 {
                Capsule()
                    .fill(pctColor(pct))
                    .frame(width: max(barHeight, fill), height: barHeight)
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
        if data.didCompact {
            lines.append("Recently compacted")
        }
        return lines.joined(separator: "\n")
    }

    private func pctColor(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .secondary
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
         > StatusBarView.CollapseThreshold.cliVersionIcon
         && StatusBarView.CollapseThreshold.cliVersionIcon
         > StatusBarView.CollapseThreshold.branchIcon
         && StatusBarView.CollapseThreshold.branchIcon
         > StatusBarView.CollapseThreshold.dropContextNumeric
         && StatusBarView.CollapseThreshold.dropContextNumeric
         > StatusBarView.CollapseThreshold.popoverFallback)
}()
#endif
