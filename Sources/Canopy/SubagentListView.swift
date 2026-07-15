import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SubagentListView")

/// CLI-style subagent task list — mirrors the bottom-of-terminal agent rows
/// Claude Code shows while Agent / Task tool calls run. Data comes from
/// `StatusBarData.subagents` (snapshot of `SubagentTracker.rows`).
struct SubagentListView: View {
    let data: StatusBarData

    var body: some View {
        if data.subagents.isEmpty {
            EmptyView()
        } else {
            // Tick once a second while any row is still running so elapsed
            // times stay live; idle at 1h when everything is finished. The
            // cadence flips only when `body` re-runs — i.e. when
            // `data.subagents` mutates, since that's the observation. So
            // "idle at 1h" only kicks in after the final row's state update
            // lands; TimelineView doesn't self-reevaluate `anyRunning`
            // between ticks.
            let anyRunning = data.subagents.contains(where: \.isRunning)
            TimelineView(.periodic(from: .now, by: anyRunning ? 1 : 3600)) { context in
                listContent(now: context.date)
            }
            // Watchdog: if the probe never lands (JS selector broke, auth
            // screen with no chat, etc.) the fallback width persists
            // silently and the row detaches from the input column on wide
            // windows. Log at info level so the failure is grep-able.
            .task(id: data.subagents.count) {
                try? await Task.sleep(for: .seconds(5))
                if data.chatInputWidth == nil {
                    logger.info("chatInputWidth still nil after 5s — probe may not have attached")
                }
            }
        }
    }

    /// Fallback width when the JS probe hasn't reported yet (auth screen,
    /// initial load). Slightly under the empirically-measured 680pt at a
    /// 1059pt viewport so the first live probe report always expands the
    /// row (never contracts it) — reads cleaner than jitter in either
    /// direction.
    private static let fallbackContentWidth: CGFloat = 640

    @ViewBuilder
    private func listContent(now: Date) -> some View {
        // Live width from the webview's chat-input column (see
        // `InputWidthProbe`). Falls back to a sensible default the moment
        // the webview is up but the probe hasn't reported yet.
        let contentWidth = data.chatInputWidth ?? Self.fallbackContentWidth
        let rows = VStack(alignment: .leading, spacing: 3) {
            ForEach(data.subagents) { agent in
                row(agent, now: now)
            }
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.white)

        // Cap height so a huge fan-out of Agent calls can't eat the webview.
        if data.subagents.count > 8 {
            ScrollView {
                rows
            }
            .frame(maxHeight: 190)
        } else {
            rows
        }
    }

    private func row(_ agent: SubagentInfo, now: Date) -> some View {
        HStack(spacing: 6) {
            Group {
                if agent.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                }
            }
            .frame(width: 14, height: 14)

            // Match StatusBarView's tone hierarchy so the two footers read
            // as one strip: secondary for the primary label, tertiary for
            // secondary metadata (agent type + trailing metrics).
            Text(agent.agentType)
                .foregroundStyle(.tertiary)
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(agent.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(trailingText(agent, now: now))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
    }

    private func trailingText(_ agent: SubagentInfo, now: Date) -> String {
        let elapsed = formatElapsed(agent.elapsed(now: now))
        if agent.tokens == 0 {
            return elapsed
        }
        return "\(elapsed) · ↓ \(formatTokens(agent.tokens)) tokens"
    }

    /// Under 60s → "42s"; otherwise "2m 38s".
    private func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes)m \(seconds)s"
    }

    /// CLI-style token counts: 1.2M / 65.8k / 42.
    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
