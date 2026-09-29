import Foundation

/// The settings the daemon acts on, read straight from the shared
/// settings.json. Not `CanopySettings`: that instance is loaded once and
/// rewrites the file on load, while the GUI changes these keys in another
/// process and the daemon must follow without writing anything back.
struct DaemonConfig: Equatable {
    var mirrorEnabled: Bool
    var allowBypass: Bool
    var daemonPort: Int

    static let defaults = DaemonConfig(mirrorEnabled: false, allowBypass: false, daemonPort: 8767)

    /// Defaults for a missing file; nil for one that does not parse. The GUI
    /// writes it non-atomically, so a read can land mid-write, and treating that
    /// as "Mirror off" would drop every remote client.
    static func parse(_ data: Data?) -> DaemonConfig? {
        guard let data else { return defaults }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var config = defaults
        if let on = dict["canopy.mirrorEnabled"] as? Bool { config.mirrorEnabled = on }
        if let allow = dict["claudeCode.allowDangerouslySkipPermissions"] as? Bool { config.allowBypass = allow }
        if let port = dict["canopy.daemonPort"] as? Int, (1...65535).contains(port) { config.daemonPort = port }

        return config
    }
}
