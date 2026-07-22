import SwiftUI

/// Weight-based proportional multi-pane layout.
///
/// - `sizeThatFits` returns the parent's proposed width verbatim. This is
///   what prevents the "SwiftUI grows the window to fit the HStack's
///   intrinsic width" feedback loop — the layout never asks for more space
///   than the parent offered.
/// - `placeSubviews` computes each pane's actual width via the CSS-flex
///   style iterative pin-to-floor algorithm in `PaneLayoutMetrics`, then
///   places each subview at its computed width.
///
/// Callers pass one subview per pane (paneCell + trailing PaneDivider
/// bundled inside), and the layout uses column-width = pane-width + (its
/// trailing divider width if any).
enum PaneLayoutMetrics {
    /// Weight-based proportional pane widths with a per-pane minimum.
    /// Uses the CSS flex-grow algorithm: distribute by weight; any pane
    /// that would end up below `minimumWidth` gets pinned there and the
    /// remaining space is re-distributed among the rest. Terminates
    /// because each iteration either finalizes at least one pane or all
    /// remaining panes fit their weighted share.
    static func paneWidths(
        detailWidth: CGFloat,
        weights: [CGFloat],
        dividerWidth: CGFloat,
        minimumWidth: CGFloat
    ) -> [CGFloat] {
        let count = weights.count
        guard count > 0 else { return [] }

        let dividerTotal = CGFloat(max(0, count - 1)) * dividerWidth
        var remainingWidth = max(0, detailWidth - dividerTotal)
        var result = Array(repeating: CGFloat.zero, count: count)
        var active = Array(0..<count)

        while !active.isEmpty {
            let activeWeight = active.reduce(CGFloat.zero) { $0 + weights[$1] }
            guard activeWeight > 0 else {
                // Zero-weight edge case: equal-share the remaining space.
                let share = remainingWidth / CGFloat(active.count)
                for index in active {
                    result[index] = max(minimumWidth, share)
                }
                break
            }

            var candidates: [Int: CGFloat] = [:]
            for index in active {
                candidates[index] = remainingWidth * (weights[index] / activeWeight)
            }

            let fixed = active.filter { candidates[$0]! < minimumWidth }

            if fixed.isEmpty {
                for index in active {
                    result[index] = candidates[index]!
                }
                break
            }

            for index in fixed {
                result[index] = minimumWidth
            }

            remainingWidth -= CGFloat(fixed.count) * minimumWidth
            active.removeAll { fixed.contains($0) }
        }

        return result
    }
}

struct WeightedPaneLayout: Layout {
    typealias Cache = ()

    let weights: [CGFloat]
    let dividerWidth: CGFloat
    let minimumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let count = subviews.count
        let dividerTotal = CGFloat(max(0, count - 1)) * dividerWidth

        let fallbackWidth = max(
            weights.reduce(0, +) + dividerTotal,
            CGFloat(count) * minimumWidth + dividerTotal
        )

        // Return the parent's proposed width verbatim when it's non-nil.
        // This is the critical bit that prevents NavigationSplitView from
        // growing the window to fit the HStack's "ideal" content size.
        let width = proposal.width ?? fallbackWidth

        let height = proposal.height
            ?? subviews
                .map {
                    $0.sizeThatFits(
                        ProposedViewSize(width: nil, height: nil)
                    ).height
                }
                .max()
            ?? 0

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard !subviews.isEmpty else { return }

        // Each subview is expected to be a pane + its trailing divider
        // bundled together. Compute pane widths, then place each subview
        // at pane-width + trailing-divider-width.
        let widths = PaneLayoutMetrics.paneWidths(
            detailWidth: bounds.width,
            weights: weights,
            dividerWidth: dividerWidth,
            minimumWidth: minimumWidth
        )

        var x = bounds.minX

        for index in subviews.indices {
            let hasTrailingDivider = index < subviews.count - 1
            let paneW = index < widths.count ? widths[index] : 0
            let columnWidth = paneW + (hasTrailingDivider ? dividerWidth : 0)

            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: columnWidth,
                    height: bounds.height
                )
            )

            x += columnWidth
        }
    }
}
