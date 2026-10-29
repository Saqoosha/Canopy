import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DockBadge")

/// Puts the number of sessions that are owed a look on the Dock icon: the
/// ones asking for permission or an answer, and the ones that finished a turn
/// nobody has acknowledged yet. Both come from `SessionActivity`, so the
/// count is exactly the orange and green dots in the sidebar.
///
/// Reads `unreadSessionIds`, which `MacroPadController` maintains whether or
/// not a pad is plugged in, so the badge needs no tracker of its own.
@MainActor
final class DockBadge {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        track()
    }

    private func track() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            // Same hop as `MacroPadController.track()`: `onChange` fires before
            // the mutation lands.
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private func refresh() {
        let unread = store.unreadSessionIds
        let count = store.openSessions.filter { session in
            switch SessionActivity.of(session, isUnread: unread.contains(session.id)) {
            case .asking, .unread: return true
            default: return false
            }
        }.count
        let label = count > 0 ? String(count) : nil
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
            logger.notice("Dock badge: \(label ?? "-", privacy: .public)")
        }
    }
}
