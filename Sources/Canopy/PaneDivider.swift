import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "PaneDivider")

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
/// Why disable the whole cursor-rect system for the drag: every layout
/// tick that resizes the adjacent `WKWebView`s calls
/// `invalidateCursorRects(for:)` up the view hierarchy, which schedules
/// a `resetCursorRects()` walk that briefly reasserts the default arrow
/// *before* the next `onChanged` re-applies the resize cursor. Rejected
/// alternatives:
/// - `.onHover { push/pop }` alone — same invalidation race pops the
///   stack mid-drag.
/// - `NSCursor.push()` + an `NSEvent.addLocalMonitorForEvents` that
///   re-`.set()`s on `mouseMoved` — Apple DTS specifically flags this
///   pattern as a *source* of flicker rather than a cure (see forum
///   thread linked below).
/// `NSWindow.disableCursorRects()` for the drag duration is the
/// battle-tested workaround.
///
/// Reference: Apple Developer Forums thread #708211 — "NSCursor reset
/// to arrow". https://developer.apple.com/forums/thread/708211
///
/// # Interruption recovery
///
/// `SwiftUI.DragGesture.onEnded` is known to *not* fire when a drag
/// is cancelled by focus loss, Mission Control, Spotlight, Cmd+Tab, or
/// a competing gesture recognizer (FB13559963). Without any recovery
/// path, `pushed == true` would remain true forever, the resize cursor
/// would stay on the stack, and cursor rects would stay disabled on
/// EVERY window app-wide — including Settings, Sparkle alerts, and
/// permission dialogs — until the user completes another uninterrupted
/// drag on this same divider. `deinit` is NOT a valid backstop here:
/// it only fires when the `@State`-retained `DragCursorLock` instance
/// is deallocated, which happens when the divider view is torn down
/// (pane close) — not when a live view's gesture is merely cancelled.
///
/// The recovery mechanism is a pair of listeners installed at `engage`
/// and torn down at `release`:
///
///   - `NSApplication.didResignActiveNotification`: fires the moment
///     Canopy loses active status (Cmd+Tab, Mission Control, etc.).
///   - `NSEvent.addGlobalMonitorForEvents(.leftMouseUp)`: fires when
///     the user releases the mouse button in *any* application,
///     including one Canopy has been switched away from.
///
/// # Race protection
///
/// `deinit` cannot touch AppKit APIs directly under Swift 6 strict
/// concurrency (the class is not `@MainActor`; deinit runs on the last
/// releaser thread), so it dispatches enablement to main asynchronously.
/// If a *fresh* `DragCursorLock` engages between the deinit dispatch and
/// its execution, the async block would silently undo the fresh lock's
/// disable — the exact "cursor flickers back to default during drag"
/// symptom we exist to prevent. Guard: `Self.active` weakly points at
/// the currently-engaged lock; the deinit only re-enables cursor rects
/// when `Self.active === nil`, i.e. no successor is holding the lock.
///
/// # Type isolation
///
/// The type has no actor annotation, so `deinit` is nonisolated and can
/// read `pushed` (marked `nonisolated(unsafe)`) under Swift 6 strict
/// concurrency. `engage()` / `release()` are `@MainActor` for the AppKit
/// calls. A reference type is required because value types have no
/// destructor hook for the interrupted-teardown backstop.
///
/// Stored in `@State` on `PaneDivider` so the same instance is reused
/// across body re-invocations (the view struct is recreated dozens of
/// times per second during drag). SwiftUI's `@State` default-value
/// expression is re-evaluated on every struct init but only the first
/// instance is kept; discarded instances have `pushed == false` and
/// their deinit early-returns.
/// `@unchecked Sendable` because we manage thread safety manually:
/// `pushed` / `interruptObserver` / `globalMouseUpMonitor` are only
/// mutated from `@MainActor` methods (engage/release), and deinit
/// (which runs when the last reference drops) synchronously hops back
/// to main via `MainActor.assumeIsolated` before touching any of them.
/// Marking the class Sendable lets `[weak self]` closures in the
/// notification/monitor callbacks compile cleanly under Swift 6.
private final class DragCursorLock: @unchecked Sendable {
    /// Currently-engaged lock, if any. Written from `engage`/`release`
    /// on the main actor; read from `deinit` inside
    /// `MainActor.assumeIsolated` so no cross-actor race is possible.
    @MainActor
    private static weak var active: DragCursorLock?

    nonisolated(unsafe) private var pushed = false
    nonisolated(unsafe) private var interruptObserver: NSObjectProtocol?
    nonisolated(unsafe) private var globalMouseUpMonitor: Any?

    @MainActor
    func engage() {
        guard !pushed else {
            // Silent under normal use (onChanged fires many times per
            // drag), but if a fresh onChanged fires without an intervening
            // release — SwiftUI gesture-arbitration edge case — the log
            // makes it discoverable rather than hiding it.
            logger.debug("engage: no-op, already engaged")
            return
        }
        // Defensive release of any prior lock; normally release() runs
        // before a new engage but we guard for reentrancy just in case.
        if let prior = Self.active, prior !== self {
            logger.warning("engage: releasing prior active lock (unexpected)")
            prior.release()
        }
        // Disable cursor rects on EVERY window (not just keyWindow).
        // Forum reporters found key-window-only suppression was still
        // beaten by app-level invalidation triggers.
        for window in NSApp.windows {
            window.disableCursorRects()
        }
        NSCursor.resizeLeftRight.push()
        pushed = true
        Self.active = self
        installInterruptSafety()
    }

    @MainActor
    func release() {
        guard pushed else {
            logger.debug("release: no-op, was not engaged")
            return
        }
        NSCursor.pop()
        for window in NSApp.windows {
            window.enableCursorRects()
        }
        removeInterruptSafety()
        if Self.active === self { Self.active = nil }
        pushed = false
    }

    @MainActor
    private func installInterruptSafety() {
        // Focus loss recovery: NSApplication.didResignActive covers
        // Cmd+Tab, Mission Control, Spotlight, and any other app-level
        // deactivation. Fires on the main queue explicitly.
        interruptObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                logger.info("release triggered by app resign-active (interrupted drag)")
                self?.release()
            }
        }
        // Cross-app mouse-up: local monitor catches events routed to
        // Canopy; global monitor catches events routed to OTHER apps
        // (e.g. user Cmd+Tabbed away then released the mouse). Together
        // they cover every mouse-up regardless of which app is active.
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            // Global monitor callbacks are invoked on the main thread
            // per NSEvent docs, but the closure signature is not
            // MainActor-isolated. `assumeIsolated` traps if the assumed
            // isolation is ever violated in a future macOS SDK — better
            // a loud crash than a silent data race.
            MainActor.assumeIsolated {
                logger.info("release triggered by global mouseUp (drag ended off-app)")
                self?.release()
            }
        }
    }

    @MainActor
    private func removeInterruptSafety() {
        if let observer = interruptObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptObserver = nil
        }
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
    }

    deinit {
        // Fires only when the divider view identity is torn down (pane
        // close, tab close). Live gesture interruption is handled by
        // installInterruptSafety()'s observers, not here — deinit does
        // NOT fire mid-drag if the view survives.
        //
        // Rescue path for the edge case where the divider itself is
        // unmounted while engaged. SwiftUI `@State` teardown runs on
        // the main thread in practice; `MainActor.assumeIsolated`
        // traps loudly if that ever changes — better than a silent
        // data race on the AppKit calls or the shared cursor stack.
        // The `Sendable` route (DispatchQueue.main.async) would
        // require every captured `NSObjectProtocol` / `Any` to be
        // Sendable, which they're not.
        guard pushed else { return }
        MainActor.assumeIsolated {
            NSCursor.pop()
            // If a fresh lock has already engaged (took over Self.active),
            // do NOT re-enable cursor rects — that would silently undo
            // the new lock's disable and reintroduce the flicker this
            // class exists to prevent.
            if Self.active == nil {
                for window in NSApp.windows {
                    window.enableCursorRects()
                }
            }
            if let observer = interruptObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let monitor = globalMouseUpMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
