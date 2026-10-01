import AppKit
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "PendingUpdate")

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
            // Outside launchd nothing would start the new build, so nothing here is "about to" happen.
            if state.notUnderLaunchd { return "Update ready — the session service will not restart on its own" }
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

    /// Restarts one session's shim on the newest extension, keeping its conversation.
    private func restart(_ row: StaleExtensionSession) {
        guard let store = SessionStore.shared,
              let session = store.openSessions.first(where: { $0.daemonKey == row.key }) else {
            error = "\(row.title) is not open in this window."
            return
        }
        // The row's blocker is up to a minute old; this pane's own flags are current.
        let liveBusy = session.isThinking || session.isAsking || session.isWaiting ? "it is working" : nil
        if let blocker = row.blocker ?? liveBusy {
            let alert = NSAlert()
            alert.messageText = "Restart \(row.title)?"
            alert.informativeText = "It is busy: \(blocker). Restarting stops its current work. The conversation is kept."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.restartSession(session.id)
    }

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
            if let ext = state.extensionState, !ext.stale.isEmpty {
                if state.pendingBuild != nil { Divider() }
                Text("Extension \(ext.installed) is installed; these sessions still run an older one.")
                    .font(.headline)
                ForEach(ext.stale, id: \.key) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.system(size: 12, weight: .medium))
                            Text(row.blocker.map { "\(row.running) · \($0)" } ?? row.running)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart") { restart(row) }
                    }
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let control = SessionStore.shared?.daemonControl else {
            error = "Could not restart: not connected to the session service."
            return
        }
        PendingUpdate.shared.restarting = true
        Task { @MainActor in
            guard case .failure(let failure) = await control.request("restart_now") else { return }
            PendingUpdate.shared.restarting = false
            let reason = switch failure {
            case .refused(let message): message
            case .disconnected: "not connected to the session service"
            case .timedOut: "the session service did not answer"
            }
            logger.error("restart_now failed: \(reason, privacy: .public)")
            error = "Could not restart: \(reason)."
        }
    }
}
