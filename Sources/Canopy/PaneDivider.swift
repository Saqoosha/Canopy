import AppKit
import SwiftUI

/// Vertical divider between two panes. Visible 1 pt line + 8 pt drag
/// target. Drag adjusts the two adjacent panes' preferredWidth; sum is
/// preserved so the outer window width does not change. Per-pane floor:
/// 100 pt (SessionStore.paneMinDragWidth).
struct PaneDivider: View {
    @Bindable var store: SessionStore
    let leftIndex: Int
    @State private var dragStartLeft: CGFloat = 0
    @State private var dragStartRight: CGFloat = 0
    /// Locks the cursor to `resizeLeftRight` for the drag duration by
    /// suspending AppKit's cursor-rect invalidation on every window.
    /// See `DragCursorLock`.
    @State private var cursorLock = DragCursorLock()

    var body: some View {
        ZStack {
            // AppKit-managed cursor rect: uses the platform's built-in
            // cursor-rect system so the hover cursor is `resizeLeftRight`
            // before the drag starts. During the drag, `DragCursorLock`
            // takes over — cursor rects are the WRONG mechanism there
            // because they get invalidated on every re-layout tick.
            ResizeCursorArea().frame(width: 8) // drag target
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)               // visible line
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // Use .global coordinate space so translation reflects the mouse's
        // absolute movement, independent of the HStack's re-layout as
        // panes' preferredWidth changes on each onChanged. Local
        // coordinate space would race the re-layout and produce jitter /
        // "divider not under the mouse" behavior.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    // Engage the cursor lock on the first tick. Idempotent.
                    cursorLock.engage()
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
                    cursorLock.release()
                    dragStartLeft = 0
                    dragStartRight = 0
                }
        )
    }
}

/// NSViewRepresentable that reserves its bounds as a resize-left-right
/// cursor area via AppKit's cursor-rect system. Handles the *hover*
/// case only — the *drag* case can't rely on cursor rects because every
/// pane resize tick invalidates them, briefly reasserting the default
/// arrow before we can override it.
private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorRectView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorRectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}

/// Locks the pointer to `NSCursor.resizeLeftRight` for the lifetime of
/// an active pane-divider drag by *disabling* AppKit's per-window
/// cursor-rect invalidation and pushing the resize cursor onto the
/// cursor stack.
///
/// Why this and not `.push()` + `NSEvent.addLocalMonitorForEvents(mouseMoved/dragged)`
/// alone: the earlier version of this file did exactly that and the
/// cursor still flickered to the default arrow between drag ticks.
/// Root cause per Apple DTS on the developer forums: every layout tick
/// that resizes the adjacent `WKWebView`s calls
/// `invalidateCursorRects(for:)` up the view hierarchy, which schedules
/// a `resetCursorRects()` walk that briefly reasserts the default
/// arrow *before* the next `onChanged` re-`set()`s. Adding an
/// `NSEvent` monitor that re-`set()`s on every mouse motion was found
/// to be a *source* of flicker rather than a fix — DTS specifically
/// advised against forcing `.set()` in `mouseMoved`. WKWebView also
/// runs its own cursor IPC from the content process, but in practice
/// `disableCursorRects()` is enough for the pane-divider case.
///
/// Reference: Apple Developer Forums thread #708211 ("NSCursor reset
/// to arrow") — "an ugly hack, but otherwise the cursor gets reset".
///
/// Reference-type wrapper stored in `@State` so the same instance is
/// reused across body re-invocations (the view struct is recreated
/// dozens of times per second during drag; a value-type wrapper would
/// drop the state on every recreation), and the `deinit` backstop
/// fires exactly once when the view is torn down.
///
/// Class isolation: nonisolated so `deinit` can touch stored
/// properties under Swift 6 strict concurrency. `engage()` / `release()`
/// are marked `@MainActor` for the AppKit calls.
private final class DragCursorLock {
    nonisolated(unsafe) private var pushed = false

    @MainActor
    func engage() {
        guard !pushed else { return }
        // Disable cursor rects on EVERY window (not just keyWindow).
        // Forum reporters found key-window-only suppression was still
        // beaten by app-level invalidation triggers.
        for window in NSApp.windows {
            window.disableCursorRects()
        }
        NSCursor.resizeLeftRight.push()
        pushed = true
    }

    @MainActor
    func release() {
        guard pushed else { return }
        NSCursor.pop()
        for window in NSApp.windows {
            window.enableCursorRects()
        }
        pushed = false
    }

    deinit {
        // Backstop for the interrupted-drag path (gesture cancels
        // without onEnded — key window loses focus, Mission Control,
        // etc.). Without re-enabling cursor rects on the surviving
        // windows, hover cursors elsewhere in the app would stay
        // frozen at whatever they were the moment the drag started.
        // `NSCursor.pop` is thread-safe; hop to main for
        // `enableCursorRects` + `NSApp.windows`.
        guard pushed else { return }
        NSCursor.pop()
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.enableCursorRects()
            }
        }
    }
}
