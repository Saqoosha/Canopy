import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopySettings")

@Observable
final class CanopySettings {
    nonisolated(unsafe) static let shared = CanopySettings()

    var allowDangerouslySkipPermissions: Bool = false {
        didSet { save() }
    }
    var useCtrlEnterToSend: Bool = false {
        didSet { save() }
    }
    var respectGitIgnore: Bool = true {
        didSet { save() }
    }

    let filePath: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let canopyDir = appSupport.appendingPathComponent("Canopy")
        self.filePath = canopyDir.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.info("No settings file found, using defaults")
            return
        }

        if let allow = dict["claudeCode.allowDangerouslySkipPermissions"] as? Bool {
            allowDangerouslySkipPermissions = allow
        }
        if let ctrl = dict["claudeCode.useCtrlEnterToSend"] as? Bool {
            useCtrlEnterToSend = ctrl
        }
        if let git = dict["claudeCode.respectGitIgnore"] as? Bool {
            respectGitIgnore = git
        }
        logger.info("Loaded settings: allowBypass=\(self.allowDangerouslySkipPermissions, privacy: .public)")
    }

    private func save() {
        var dict = loadCurrentDict()
        dict["claudeCode.allowDangerouslySkipPermissions"] = allowDangerouslySkipPermissions
        dict["claudeCode.useCtrlEnterToSend"] = useCtrlEnterToSend
        dict["claudeCode.respectGitIgnore"] = respectGitIgnore
        writeDict(dict)
    }

    /// Remove any SSH wrapper path written by pre-env-var Canopy builds.
    /// Preserves wrappers set by the user or other tools (e.g. custom tracing
    /// wrappers) by only clearing values that point at our bundled script.
    func clearStaleSSHWrapper() {
        var dict = loadCurrentDict()
        guard let current = dict["claudeCode.claudeProcessWrapper"] as? String,
              (current as NSString).lastPathComponent == "ssh-claude-wrapper.sh"
        else { return }
        dict.removeValue(forKey: "claudeCode.claudeProcessWrapper")
        writeDict(dict)
        logger.info("Cleared stale SSH wrapper from settings: \(current, privacy: .public)")
    }

    private func loadCurrentDict() -> [String: Any] {
        guard let data = try? Data(contentsOf: filePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private func writeDict(_ dict: [String: Any]) {
        do {
            let dir = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: filePath)
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
