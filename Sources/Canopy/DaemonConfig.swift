import Foundation

/// The three settings the daemon acts on, read straight from the shared
/// settings.json. Not `CanopySettings`: that instance is loaded once and
/// rewrites the file on load, while the GUI changes these keys in another
/// process and the daemon must follow without writing anything back.
struct DaemonConfig: Equatable {
    var mirrorEnabled: Bool
    var allowBypass: Bool
    var daemonPort: Int

    static let defaults = DaemonConfig(mirrorEnabled: false, allowBypass: false, daemonPort: 8767)

    static func parse(_ data: Data?) -> DaemonConfig {
        guard let data, let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return defaults }
        var config = defaults
        if let on = dict["canopy.mirrorEnabled"] as? Bool { config.mirrorEnabled = on }
        if let allow = dict["claudeCode.allowDangerouslySkipPermissions"] as? Bool { config.allowBypass = allow }
        if let port = dict["canopy.daemonPort"] as? Int, (1...65535).contains(port) { config.daemonPort = port }
        return config
    }
}
