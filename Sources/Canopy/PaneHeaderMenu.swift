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
        switch store.panes[index].content {
        case .session(let openId):
            guard let session = store.openSessions.first(where: { $0.id == openId }) else { return false }
            menu.addItem(ClosureMenuItem(title: "Rename…") { [weak store] in
                store?.beginRenameForPane(at: index)
            })
            menu.addItem(ClosureMenuItem(title: "Restart session") { [weak store] in
                store?.restartSession(session.id)
            })
            menu.addItem(ClosureMenuItem(title: "Close session") { [weak store] in
                store?.closeSession(session.id)
            })
            // Absent, not disabled, for a remote session: the directory is on
            // the other machine, so there is no local folder the item could
            // ever open. A greyed row would read as "not right now".
            if session.origin.remoteHost == nil {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Open in Finder") { [weak store] in
                    store?.revealInFinder(session.origin.workingDirectory)
                })
            }
        case .launcher:
            menu.addItem(ClosureMenuItem(title: "Close pane") { [weak store] in
                store?.closePane(at: index)
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
/// — a pane index and a session id — is not an object that could be the
/// target. Storing the closure on the item and making it its own target is the
/// smallest way out; the menu owns its items, so the closure lives exactly as
/// long as the menu does.
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
