import IOKit.pwr_mgt
import Observation
import SwiftUI

/// Whether a Canopy process (the daemon, usually) is keeping the Mac awake, read from the
/// system's assertion list rather than over the control socket: `SleepGuard` names its
/// assertion `SleepGuard.assertionName` and puts the reason in Details.
@MainActor @Observable
final class AwakeStatus {
    static let shared = AwakeStatus()

    /// The reason the Mac is held awake, or nil when nothing of ours holds it.
    private(set) var reason: String?
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let next = Self.currentReason()
        if next != reason { reason = next }
    }

    nonisolated static func currentReason() -> String? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return nil }
        let name = SleepGuard.assertionName
        for assertions in byPid.values {
            if let ours = assertions.first(where: { $0[kIOPMAssertionNameKey] as? String == name }) {
                return ours[kIOPMAssertionDetailsKey] as? String ?? "keeping the Mac awake"
            }
        }
        return nil
    }
}

/// A small glyph in the sidebar footer while the Mac is held awake; nothing otherwise.
struct AwakeIndicator: View {
    private let status = AwakeStatus.shared

    var body: some View {
        // Started from `applicationDidFinishLaunching`: a `.task` here would never run
        // while the view draws nothing.
        if let reason = status.reason {
            Image(systemName: "cup.and.saucer.fill")
                .help("Keeping the Mac awake: \(reason)")
        }
    }
}
