import SwiftUI

struct StatusBarView: View {
    let data: StatusBarData

    var body: some View {
        // TimelineView ticks every 60s so rate-limit reset countdowns stay fresh.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            statusBar(now: context.date)
        }
    }

    private func statusBar(now: Date) -> some View {
        HStack(spacing: 0) {
            // CLI version + Model
            segment {
                if !data.cliVersion.isEmpty {
                    Text("v\(data.cliVersion)")
                }
                if !data.model.isEmpty {
                    Text("[\(data.model)]")
                }
            }

            // VCS branch (git or jj)
            if !data.gitBranch.isEmpty {
                dot
                segment {
                    switch data.vcsType {
                    case .jj:
                        Text("🥋").font(.system(size: 9))
                    default:
                        Text("🌿").font(.system(size: 9))
                    }
                    Text(data.gitBranch)
                        .foregroundStyle(.green)
                }
            }

            // Context usage: 171K/1.0M ██▒▒ 17%
            if data.contextMax > 0 {
                dot
                segment {
                    Text("\(data.formatTokens(data.contextUsed))/\(data.formatTokens(data.contextMax))")
                    ProgressView(value: Double(data.contextPct), total: 100)
                        .frame(width: 36)
                        .tint(pctColor(data.contextPct))
                    Text("\(data.contextPct)%")
                        .foregroundStyle(pctColor(data.contextPct))
                    if data.didCompact {
                        Text("↻")
                            .foregroundStyle(.blue)
                            .help("Context was compacted")
                    }
                }
            }

            // 5hr: 55% ⏳18m
            if data.sessionPct > 0 {
                dot
                segment {
                    Text("5hr:\(data.sessionPct)%")
                        .foregroundStyle(pctColor(data.sessionPct))
                    let reset = StatusBarData.formatResetTime(data.sessionResetDate)
                    if !reset.isEmpty {
                        Text("⏳\(reset)")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Wk: 45% ⏳4d
            if data.weeklyPct > 0 {
                dot
                segment {
                    Text("Wk:\(data.weeklyPct)%")
                        .foregroundStyle(pctColor(data.weeklyPct))
                    let reset = StatusBarData.formatResetTime(data.weeklyResetDate)
                    if !reset.isEmpty {
                        Text("⏳\(reset)")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Message count
            if data.messageCount > 0 {
                dot
                segment {
                    Text("💬\(data.messageCount)")
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var dot: some View {
        Text(" · ").foregroundStyle(.quaternary)
    }

    @ViewBuilder
    private func segment(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 3) { content() }
    }

    private func pctColor(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .secondary
    }
}
