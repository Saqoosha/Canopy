import SwiftUI

struct StatusBarView: View {
    let data: StatusBarData
    private var rateLimit: SharedRateLimitData { SharedRateLimitData.shared }

    var body: some View {
        // TimelineView ticks every 60s so rate-limit reset countdowns stay fresh.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            statusBar(now: context.date)
        }
    }

    // MARK: - Main layout

    private func statusBar(now _: Date) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // Remote host
            if let remote = data.remoteHost {
                pill(remote, icon: "network", color: .orange)
                    .help("SSH remote: \(remote)")
                separator
            }

            // Model + Version
            HStack(spacing: 5) {
                if !data.model.isEmpty {
                    pill(shortModelName(data.model), color: .purple)
                        .help(data.model)
                }
                if !data.cliVersion.isEmpty {
                    Text("v\(data.cliVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // VCS branch
            if !data.gitBranch.isEmpty {
                separator
                let vcsEmoji = data.vcsType == .jj ? "🥋" : "🌿"
                pill("\(vcsEmoji)\u{2009}\(data.gitBranch)", color: .green)
                    .help("Branch: \(data.gitBranch)")
            }

            // Context usage
            if data.contextMax > 0 {
                separator
                HStack(spacing: 5) {
                    Text("\(data.formatTokens(data.contextUsed))/\(data.formatTokens(data.compactionWindow))")
                    thinBar(pct: data.contextPct)
                    Text("\(data.contextPct)%")
                        .foregroundStyle(pctColor(data.contextPct))
                    if data.didCompact {
                        Text("↻")
                            .foregroundStyle(.blue)
                    }
                }
                .help("Context: \(data.formatTokens(data.contextUsed)) / \(data.formatTokens(data.compactionWindow)) tokens\(data.didCompact ? " (compacted)" : "")")
            }

            // 5hr rate limit (shared across all tabs)
            if rateLimit.sessionResetDate != nil {
                separator
                rateLimitSegment(label: "5hr", pct: rateLimit.sessionPct, resetDate: rateLimit.sessionResetDate)
            }

            // Weekly rate limit (shared across all tabs)
            let weeklyResetDate = rateLimit.effectiveWeeklyResetDate(for: data.model)
            if weeklyResetDate != nil {
                separator
                rateLimitSegment(label: "Wk", pct: rateLimit.effectiveWeeklyPct(for: data.model), resetDate: weeklyResetDate)
            }

            // Message count
            if data.messageCount > 0 {
                separator
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 8))
                    Text("\(data.messageCount)")
                }
                .foregroundStyle(.tertiary)
                .help("Messages: \(data.messageCount)")
            }

            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background(Color(red: 0xF3/255, green: 0xF4/255, blue: 0xF5/255))
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

    private func rateLimitSegment(label: String, pct: Int, resetDate: Date?) -> some View {
        let reset = StatusBarData.formatResetTime(resetDate)
        return HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.tertiary)
            thinBar(pct: pct)
            Text("\(pct)%")
                .foregroundStyle(pctColor(pct))
            if !reset.isEmpty {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .help("\(label) usage: \(pct)%\(reset.isEmpty ? "" : " — resets in \(reset)")")
    }

    // MARK: - Helpers

    private func pctColor(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .secondary
    }

    private func shortModelName(_ model: String) -> String {
        // "claude-sonnet-4-5-20250514" → "Sonnet 4.5"
        // "claude-opus-4-6" → "Opus 4.6"
        let lower = model.lowercased()
        for (family, label) in [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")] {
            if lower.contains(family) {
                if let v = extractVersion(from: lower, family: family) { return "\(label) \(v)" }
                return label
            }
        }
        return model
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
