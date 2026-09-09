import AppKit

/// The context menu a pane header offers, and the AppKit plumbing that shows
/// it.
///
/// It is an `NSMenu` built by hand rather than a SwiftUI `.contextMenu` on
/// `PaneHeaderStrip` for the same reason that strip's close X is hit-tested by
/// an NSEvent monitor: macOS 26 lays the detail column's scroll-edge
/// `BackdropView` over that band, and no mouse event is known to reach what
/// the strip draws. A `.contextMenu` there would compile, look right in the
/// source, and never open.
///
/// The rows deliberately mirror `Sidebar`'s `rowMenu(for:)` — the header and
/// the row stand for the same session, so offering different verbs depending
/// on which one you right-click is the kind of difference nobody can predict.
/// The one row that does not carry over is "Hide from sidebar": it is disabled
/// for every open row anyway, and a pane header only ever stands for something
/// live.
enum PaneHeaderMenu {
    /// Pop the menu for the pane at `index`, anchored at `screenPoint`.
    ///
    /// Returns false when the pane has nothing to offer — an index that has
    /// gone away between the click and here — so the caller can pass the event
    /// through instead of consuming a right-click that showed nothing.
    @MainActor
    @discardableResult
    static func show(store: SessionStore, paneIndex index: Int, at screenPoint: CGPoint) -> Bool {
        guard store.panes.indices.contains(index) else { return false }
        let menu = NSMenu()
        // Every action addresses its target by a stable id and re-resolves the
        // pane when it fires. `popUp` below runs a nested tracking loop in
        // `NSEventTrackingRunLoopMode`, which is one of the common modes, so
        // ordinary main-queue work still runs while the menu is open — a
        // session crashing and closing its pane, a MacroPad key, a shortcut.
        // A captured `Int` index would then name a different pane, and both
        // `beginRenameForPane(at:)` and `closePane(at:)` bounds-check without
        // noticing: the rename sheet opens on the wrong session, the wrong
        // pane closes. `Sidebar.handleClose` already resolves its launcher
        // pane this way, and this mirrors it.
        switch store.panes[index].content {
        case .session(let openId):
            guard let session = store.openSessions.first(where: { $0.id == openId }) else { return false }
            // The directory is read here rather than in the closure so nothing
            // captures the `OpenSession` itself — the menu outlives the click
            // only briefly, but a strong capture of a live session object is
            // not what this file should be doing.
            let workingDirectory = session.origin.remoteHost == nil ? session.origin.workingDirectory : nil
            menu.addItem(ClosureMenuItem(title: "Rename…") { [weak store] in
                guard let store, let idx = store.paneIndex(forSession: openId) else { return }
                store.beginRenameForPane(at: idx)
            })
            menu.addItem(ClosureMenuItem(title: "Restart session") { [weak store] in
                store?.restartSession(openId)
            })
            menu.addItem(ClosureMenuItem(title: "Close session") { [weak store] in
                store?.closeSession(openId)
            })
            // Absent, not disabled, for a remote session: the directory is on
            // the other machine, so there is no local folder the item could
            // ever open. A greyed row would read as "not right now".
            if let workingDirectory {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Open in Finder") { [weak store] in
                    store?.openInFinder(workingDirectory)
                })
            }
        case .launcher:
            // `PaneContent.launcher` carries nothing, so the stable id is the
            // slot's own — the same handle `SidebarRow.launcher` uses.
            let slot = store.panes[index].id
            menu.addItem(ClosureMenuItem(title: "Close pane") { [weak store] in
                guard let store, let idx = store.paneIndex(forSlot: slot) else { return }
                store.closePane(at: idx)
            })
        }
        // `popUp(positioning:at:in:)` with a nil view takes SCREEN coordinates,
        // which is what the caller already has: an NSEvent's
        // `locationInWindow` converted through the window. Routing it through
        // the content view instead would need the flipped-vs-unflipped dance
        // for nothing.
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
        return true
    }
}

/// `NSMenuItem` that runs a closure.
///
/// `NSMenuItem` needs a target/action pair, and what these actions close over
/// — a session id, a pane slot id, a directory — is not an object that could
/// be the target. Storing the closure on the item and making it its own target
/// is the smallest way out; the menu owns its items, so the closure lives
/// exactly as long as the menu does. `NSMenuItem.target` is weak, so pointing
/// it at `self` is not a cycle.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is built in code, never from a nib")
    }

    @objc private func fire() { handler() }
}
