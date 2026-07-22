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
        .onHover { NSCursor.resizeLeftRight.set(); _ = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    guard store.panes.indices.contains(leftIndex),
                          store.panes.indices.contains(leftIndex + 1) else { return }
                    if dragStartLeft == 0 {
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
