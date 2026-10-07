import Foundation
import Observation

/// The daemon's view of updates it has not applied, for `ControlSession` to push.
/// Written only by `DaemonDelegate`; nil until its first upgrade check.
@MainActor @Observable
final class DaemonUpgradeCenter {
    static let shared = DaemonUpgradeCenter()
    var state: UpgradeState?
    /// Set by `DaemonDelegate`. Returns why it refused, or nil once the restart has begun.
    @ObservationIgnored var restartNow: (() -> String?)?
    /// Set by `DaemonDelegate`. Re-reads which sessions run an older extension, for a restart that just moved one.
    @ObservationIgnored var refreshExtensionState: (() -> Void)?
}
