import SwiftUI

/// Sticky footer at the bottom of the sidebar. Shows account-scoped rate
/// limits (5-hour and weekly) that used to live in every per-pane
/// StatusBarView. Rate limits apply to the Anthropic account, not to any
/// one session — moving them here removes the duplication across panes
/// and buys back horizontal room in per-pane status bars.
struct SidebarAccountSection: View {
    @Environment(\.displayScale) private var displayScale
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
                // Render each row only when its own reset date is present.
                // The API's `update(from:)` can populate one window (5hr /
                // weekly) without the other; showing "0%, resets whenever"
                // for the missing one would misread as "we have data".
                if let resetDate = data.sessionResetDate {
                    limitRow(label: "5hr",
                             percent: fiveHourPercent,
                             reset: fiveHourResetLabel,
                             resetDate: resetDate,
                             windowDuration: 5 * 3600)
                }
                if let resetDate = data.weeklyResetDate {
                    limitRow(label: "Wk",
                             percent: weeklyPercent,
                             reset: weeklyResetLabel,
                             resetDate: resetDate,
                             windowDuration: 7 * 24 * 3600)
                }
                // Per-model weekly buckets (e.g. "Weekly Fable") from the
                // raw get_usage payload — one row per model, same columns.
                // Pace marker omitted here: the account-scoped 5hr + weekly
                // rows already carry the "burning too fast" signal, and per-
                // model buckets are noisy under bursty usage — showing a red
                // tick on every model row would drown out the signal.
                ForEach(data.modelScoped) { scoped in
                    limitRow(label: scoped.displayName,
                             percent: Double(scoped.pct) / 100.0,
                             reset: SharedRateLimitData.formatResetTime(scoped.resetDate),
                             resetDate: nil,
                             windowDuration: 0)
                }
            }
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
    }

    private func limitRow(label: String, percent: Double, reset: String,
                          resetDate: Date?, windowDuration: TimeInterval) -> some View {
        // Every column except the bar has a fixed width so the bars in all
        // rows share the same start AND end x (the earlier free-width reset
        // label made each bar end wherever its reset text happened to be).
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 34, alignment: .leading)
            thinBar(percent: percent,
                    pacePercent: expectedPace(resetDate: resetDate, duration: windowDuration))
                .frame(maxWidth: .infinity)
                // The row's percent + reset Text views (below) already
                // read as accessible strings. Hide the Canvas from AX so
                // VoiceOver reads "5hr, 22 percent, 1h20m" and doesn't
                // land on a nameless graphic.
                .accessibilityHidden(true)
            Text("\(Int(percent * 100))%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
            Text(reset)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }

    /// Custom capsule bar — mirrors the old StatusBarView.thinBar shape
    /// (4pt tall, faint track) so the sidebar's rate-limit strip reads
    /// as a glanceable summary instead of an alert bar. Sizes itself
    /// from the enclosing `.frame(maxWidth: .infinity)` so it stretches
    /// to the sidebar's variable width.
    ///
    /// `pacePercent` (0…1) draws a CodexBar-style pace tick at the
    /// expected-usage-by-now position. Green when actual usage is at or
    /// below that expected pace (safe), red when it's above (burning the
    /// quota faster than the clock).
    private func thinBar(percent: Double, pacePercent: Double?) -> some View {
        let clamped = max(0, min(1, percent))
        let barHeight: CGFloat = 4
        // Canvas mirrors CodexBar's UsageProgressBar approach: one draw
        // pass, exact pixel alignment. SwiftUI's shape/offset combos in
        // an overlaid ZStack subpixel-rounded differently for track vs
        // marker at 4pt height, so the tick never quite sat on the bar.
        // Doing all three (track, fill, marker + halo) in one Canvas
        // guarantees they share the same coordinate space.
        return Canvas { context, size in
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)

            let trackRect = CGRect(origin: .zero, size: size)
            context.fill(
                Path { $0.addRoundedRect(in: trackRect, cornerSize: cornerSize) },
                with: .color(Color.secondary.opacity(0.15))
            )

            // Only draw the fill capsule when usage is actually > 0. Test
            // BEFORE the min-width floor, or `max(size.height, …)` makes
            // the guard always true and a 0% row shows a permanent
            // ~4pt nub (misreads as ~3–5% used on typical bar widths).
            if clamped > 0 {
                let fillWidth = max(size.height, size.width * clamped)
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                context.fill(
                    Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) },
                    with: .color(barColor(clamped))
                )
            }

            if let pace = pacePercent {
                let pacePos = max(0, min(1, pace))
                let markerWidth: CGFloat = 1
                let haloWidth: CGFloat = 3
                let extend: CGFloat = 2  // extends this many pt above and below the bar
                let centerX = size.width * pacePos
                // Snap the LEFT edge of each rect to the physical pixel
                // grid. Without this, a 1pt marker whose left edge lands on
                // a half-pt boundary antialiases across 3 physical pixels
                // (looks ~2px wide, blurry), while one that happens to
                // land on an integer boundary renders crisp 2px — the same
                // marker looks different width row to row.
                let scale = max(displayScale, 1)
                func snapLeft(_ x: CGFloat) -> CGFloat {
                    (x * scale).rounded() / scale
                }
                let haloLeft = snapLeft(max(0, min(size.width - haloWidth, centerX - haloWidth / 2)))
                let markerLeft = snapLeft(max(0, min(size.width - markerWidth, centerX - markerWidth / 2)))
                let haloRect = CGRect(x: haloLeft, y: -extend,
                                      width: haloWidth, height: size.height + extend * 2)
                let markerRect = CGRect(x: markerLeft, y: -extend,
                                        width: markerWidth, height: size.height + extend * 2)
                context.fill(Path(haloRect), with: .color(.white.opacity(0.55)))
                context.fill(
                    Path(markerRect),
                    with: .color(clamped > pacePos ? .red : .green)
                )
            }
        }
        .frame(height: barHeight)
    }

    /// Same thresholds the per-pane status bar's usage indicators use:
    /// calm gray while comfortable, orange from 50%, red from 80%.
    private func barColor(_ percent: Double) -> Color {
        if percent >= 0.8 { return .red.opacity(0.75) }
        if percent >= 0.5 { return .orange.opacity(0.8) }
        return .secondary.opacity(0.6)
    }

    /// Expected linear pace (0…1): fraction of the window that has
    /// elapsed. Returns nil when the reset date is missing, in the past,
    /// or further out than the window duration (mismatched signal — a
    /// wildly-off resetDate would place the marker somewhere misleading).
    private func expectedPace(resetDate: Date?, duration: TimeInterval) -> Double? {
        guard duration > 0, let resetDate else { return nil }
        let timeUntilReset = resetDate.timeIntervalSinceNow
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }
        let elapsed = duration - timeUntilReset
        return max(0, min(1, elapsed / duration))
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
