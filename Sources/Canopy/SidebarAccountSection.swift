import SwiftUI

/// Sticky footer at the bottom of the sidebar. Shows account-scoped rate
/// limits (5-hour and weekly) that used to live in every per-pane
/// StatusBarView. Rate limits apply to the Anthropic account, not to any
/// one session — moving them here removes the duplication across panes
/// and buys back horizontal room in per-pane status bars.
struct SidebarAccountSection: View {
    private var data: SharedRateLimitData { SharedRateLimitData.shared }

    var body: some View {
        // TimelineView ticks every 60s so reset countdowns stay fresh.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if hasAnyData {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                    .padding(.bottom, 2)
                Text("Account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                // Render each row only when its own reset date is present.
                // The API's `update(from:)` can populate one window (5hr /
                // weekly) without the other; showing "0%, resets whenever"
                // for the missing one would misread as "we have data".
                if data.sessionResetDate != nil {
                    limitRow(label: "5hr",
                             percent: fiveHourPercent,
                             reset: fiveHourResetLabel)
                }
                if data.weeklyResetDate != nil {
                    limitRow(label: "Wk",
                             percent: weeklyPercent,
                             reset: weeklyResetLabel)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func limitRow(label: String, percent: Double, reset: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            ProgressView(value: percent)
                .progressViewStyle(.linear)
                .tint(percent >= 0.8 ? .orange : .accentColor)
            Text("\(Int(percent * 100))%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
            Text(reset)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    // SharedRateLimitData has no hasSnapshot — show when either reset date
    // is present (same signal StatusBarView uses to decide visibility).
    private var hasAnyData: Bool {
        data.sessionResetDate != nil || data.weeklyResetDate != nil
    }
    private var fiveHourPercent: Double { Double(data.sessionPct) / 100.0 }
    private var weeklyPercent: Double { Double(data.weeklyPct) / 100.0 }
    private var fiveHourResetLabel: String {
        SharedRateLimitData.formatResetTime(data.sessionResetDate)
    }
    private var weeklyResetLabel: String {
        SharedRateLimitData.formatResetTime(data.weeklyResetDate)
    }
}
