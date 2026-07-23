import SwiftUI

/// Vertical divider between two panes. Visible 1 pt, drag target 8 pt.
/// Drag adjusts the two adjacent panes' preferredWidth; sum is preserved
/// so the outer window width does not change. Per-pane floor: 100 pt
/// (SessionStore.paneMinDragWidth).
struct PaneDivider: View {
    @Bindable var store: SessionStore
    let leftIndex: Int
    @State private var dragStartLeft: CGFloat = 0
    @State private var dragStartRight: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear.frame(width: 8)   // drag target
            Divider().frame(width: 1)      // visible line
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
        // Use .global coordinate space so translation reflects the mouse's
        // absolute movement, independent of the HStack's re-layout as
        // panes' preferredWidth changes on each onChanged. Local
        // coordinate space would race the re-layout and produce jitter /
        // "divider not under the mouse" behavior.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    guard store.panes.indices.contains(leftIndex),
                          store.panes.indices.contains(leftIndex + 1) else { return }
                    if dragStartLeft == 0 {
                        // Sync weights to on-screen pt widths first: the
                        // drag delta below is in pt, but after a manual
                        // window resize the stored weights are stale
                        // (larger or smaller than the visual widths), so
                        // applying a pt delta to them would move the
                        // divider slower/faster than the mouse.
                        store.normalizePaneWeightsToVisualWidths()
                        dragStartLeft = store.panes[leftIndex].preferredWidth
                        dragStartRight = store.panes[leftIndex + 1].preferredWidth
                    }
                    let dx = drag.translation.width
                    let newLeft = dragStartLeft + dx
                    let newRight = dragStartRight - dx
                    store.setAdjacentPaneWidths(
                        leftIndex: leftIndex,
                        leftWidth: newLeft,
                        rightWidth: newRight
                    )
                }
                .onEnded { _ in
                    dragStartLeft = 0
                    dragStartRight = 0
                }
        )
    }
}
