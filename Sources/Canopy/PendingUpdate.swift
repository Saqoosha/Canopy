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
            return "\(n) session\(n == 1 ? "" : "s") on an older extension"
        }
        return nil
    }

    /// The popover's headline for a waiting build, in marketing versions. Builds stand in when a
    /// version is unknown (a daemon built before the version fields sends none; the pending build
    /// is then usually this GUI's own) or when both versions match, as two dev builds can.
    nonisolated static func buildLine(_ state: UpgradeState, pending: String,
                                      ownBuild: String? = DaemonUpgrade.launchedBuild,
                                      ownVersion: String? = DaemonUpgrade.launchedVersion) -> String {
        let pendingVersion = state.pendingVersion ?? (pending == ownBuild ? ownVersion : nil)
        let (new, old): (String, String) = if let pendingVersion, let running = state.runningVersion, pendingVersion != running {
            (pendingVersion, running)
        } else {
            ("build \(pending)", "build \(state.runningBuild)")
        }
        return "Canopy \(new) is installed; the session service still runs \(old)."
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
    /// Rows already restarted from this popover, so a second click does not restart them again.
    @State private var restarted: Set<String> = []

    /// Restarts every stale session's shim on the newest extension, keeping their conversations.
    private func restartAll(_ rows: [StaleExtensionSession]) {
        error = nil
        guard let store = SessionStore.shared else {
            error = "Could not restart: no sessions are open in this window."
            return
        }
        var targets: [(row: StaleExtensionSession, session: OpenSession)] = []
        var missing: [String] = []
        for row in rows where !restarted.contains(row.key) {
            if let session = store.openSessions.first(where: { $0.daemonKey == row.key }) {
                targets.append((row, session))
            } else {
                missing.append(row.title)
            }
        }
        // A row's blocker is up to a minute old; each pane's own flags are current.
        let reasons = targets.map { target -> String? in
            let live = target.session.isThinking || target.session.isAsking || target.session.isWaiting
            return target.row.blocker ?? (live ? "working" : nil)
        }
        let busy = zip(targets, reasons).compactMap { target, reason in reason.map { "\(target.row.title): \($0)" } }
        if !busy.isEmpty {
            let idle = zip(targets, reasons).filter { $0.1 == nil }.map(\.0)
            let alert = NSAlert()
            alert.messageText = busy.count == 1 ? "1 session is busy" : "\(busy.count) sessions are busy"
            alert.informativeText = busy.joined(separator: "\n")
                + "\n\nRestarting a busy session stops its current work. Conversations are kept."
            // Return must not abort busy work, so the safe choice comes first when there is one.
            if !idle.isEmpty { alert.addButton(withTitle: "Restart \(idle.count) Idle Only") }
            alert.addButton(withTitle: "Restart All \(targets.count)")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            switch (alert.runModal(), idle.isEmpty) {
            case (.alertFirstButtonReturn, false): targets = idle
            case (.alertFirstButtonReturn, true), (.alertSecondButtonReturn, false): break
            default: return
            }
        }
        for target in targets {
            restarted.insert(target.row.key)
            store.restartSession(target.session.id)
        }
        if !missing.isEmpty { error = "Not open in this window: \(missing.joined(separator: ", "))." }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = state.pendingBuild {
                Text(PendingUpdate.buildLine(state, pending: pending))
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.system(size: 12, weight: .medium))
                        Text(row.blocker.map { "\(row.running) · \($0)" } ?? row.running)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Button(ext.stale.count == 1 ? "Restart" : "Restart All") { restartAll(ext.stale) }
                    .disabled(ext.stale.allSatisfy { restarted.contains($0.key) })
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
