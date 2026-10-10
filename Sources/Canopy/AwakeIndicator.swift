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

    /// Polls each second for a while, so a toggle shows the daemon's answer without a 10 s wait.
    func refreshSoon() {
        for delay in 1...8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
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

/// A small glyph in the sidebar footer; clicking it turns "Prevent sleep while working" on or off.
/// Filled cup while the Mac is held awake, outline while it is not, `moon.zzz` while turned off.
/// One colour for all three: the shape carries the state, so a paler glyph would only be harder to see.
struct AwakeIndicator: View {
    private let status = AwakeStatus.shared
    private let settings = CanopySettings.shared

    /// The glyph for a state; the setting wins over a held assertion the daemon has not released yet.
    static func symbol(enabled: Bool, holding: Bool) -> String {
        guard enabled else { return "moon.zzz" }
        return holding ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    var body: some View {
        // Started from `applicationDidFinishLaunching`, not a `.task` here.
        let enabled = settings.preventSleepWhileWorking
        let state = !enabled ? "Sleep prevention is off (Stay reachable too)"
            : status.reason.map { "Keeping the Mac awake: \($0)" } ?? "Not keeping the Mac awake"
        Button {
            settings.preventSleepWhileWorking.toggle()
            status.refreshSoon()
        } label: {
            // Drawn like `MacroPadIndicator`'s glyph beside it, so the two match in colour.
            // `moon.zzz` at 8.5pt inks 10pt tall, like the cup at 10pt, so both sit on one centre line.
            Image(nsImage: MacroPadIndicator.glyph(Self.symbol(enabled: enabled, holding: status.reason != nil),
                                                  color: .secondaryLabelColor, pointSize: enabled ? 10 : 8.5,
                                                  label: "Sleep prevention"))
                .frame(width: 15, height: 12)
                // The crescent carries the moon's weight below its ink centre (the zzz pulls that up).
                .offset(y: enabled ? 0 : -1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(enabled ? "On. \(state)" : "Off")
        .help("\(state). Click to turn sleep prevention \(enabled ? "off" : "on").")
    }
}
