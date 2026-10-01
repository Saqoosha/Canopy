import Foundation

/// The settings that shape the daemon's own server (the Tailscale listener
/// and the bypass gate), parsed from the shared settings.json whenever it changes.
/// `CanopySettings.reload(from:)` follows the rest from the same read.
struct DaemonConfig: Equatable {
    var mirrorEnabled: Bool
    var allowBypass: Bool
    /// The Tailscale port: `canopy.mirrorPort`, the one the GUI used to listen on, so
    /// every existing pairing (other Macs, the phone) reaches the daemon unchanged.
    var port: Int

    static let defaults = DaemonConfig(mirrorEnabled: false, allowBypass: false, port: 8770)

    /// Defaults for a missing file; nil for one that does not parse. The GUI
    /// writes it non-atomically, so a read can land mid-write, and treating that
    /// as "Mirror off" would drop every remote client.
    static func parse(_ data: Data?) -> DaemonConfig? {
        guard let data else { return defaults }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var config = defaults
        if let on = dict["canopy.mirrorEnabled"] as? Bool { config.mirrorEnabled = on }
        if let allow = dict["claudeCode.allowDangerouslySkipPermissions"] as? Bool { config.allowBypass = allow }
        if let port = dict["canopy.mirrorPort"] as? Int, (1...65535).contains(port) { config.port = port }
        return config
    }
}
