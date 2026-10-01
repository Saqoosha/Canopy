import AppKit
import Observation
import SwiftUI

/// The daemon's waiting updates as the GUI sees them (`upgrade_state`).
@MainActor @Observable
final class PendingUpdate {
    static let shared = PendingUpdate()
    var state: UpgradeState?
    /// From Restart now until the daemon reports it runs the build it was waiting for.
    var restarting = false

    /// The footer line, or nil when nothing waits.
    var line: String? { state.flatMap { Self.headline($0, restarting: restarting) } }

    nonisolated static func headline(_ state: UpgradeState, restarting: Bool) -> String? {
        if state.pendingBuild != nil {
            guard !restarting, !state.heldBy.isEmpty else { return "Update ready — restarting…" }
            let n = state.heldBy.count
            return "Update ready — waiting for \(n) session\(n == 1 ? "" : "s")"
        }
        if let ext = state.extensionState, !ext.stale.isEmpty {
            let n = ext.stale.count
            return "Extension \(ext.installed) — \(n) session\(n == 1 ? "" : "s") on an older version"
        }
        return nil
    }

    nonisolated static func confirmation(_ holds: [UpgradeHold]) -> String {
        let n = holds.count
        let names = holds.map(\.title).joined(separator: ", ")
        return "\(n) session\(n == 1 ? " is" : "s are") busy: \(names). "
            + "Restarting stops \(n == 1 ? "its" : "their") current work. Conversations are kept."
    }
}

/// One line above the version row while an update waits; click for details.
/// Mount it only while `PendingUpdate.shared.line` is non-nil: the footer's
/// `VStack` spaces every child it is given, an empty one included.
struct PendingUpdateRow: View {
    @State private var shown = false

    var body: some View {
        let pending = PendingUpdate.shared
        Button { shown = true } label: {
            Label(pending.line ?? "", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .popover(isPresented: $shown, arrowEdge: .top) {
            if let state = pending.state { PendingUpdateDetail(state: state) }
        }
    }
}

private struct PendingUpdateDetail: View {
    let state: UpgradeState
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = state.pendingBuild {
                Text("Build \(pending) is installed; the session service still runs \(state.runningBuild).")
                    .font(.headline)
                ForEach(state.heldBy, id: \.key) { hold in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hold.title).font(.system(size: 12, weight: .medium))
                        Text(hold.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !state.heldBy.isEmpty, !state.notUnderLaunchd, !PendingUpdate.shared.restarting {
                    Button("Restart now") { confirmAndRestart() }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private func confirmAndRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart the session service now?"
        alert.informativeText = PendingUpdate.confirmation(state.heldBy)
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn, let control = SessionStore.shared?.daemonControl else { return }
        PendingUpdate.shared.restarting = true
        Task { @MainActor in
            switch await control.request("restart_now") {
            case .success, .failure(.disconnected):
                // The daemon exits a second after replying; a drop here is the restart itself.
                break
            case .failure(let failure):
                PendingUpdate.shared.restarting = false
                error = "Could not restart: \(failure)"
            }
        }
    }
}
