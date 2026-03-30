import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopySettings")

@Observable
final class CanopySettings {
    nonisolated(unsafe) static let shared = CanopySettings()

    var initialPermissionMode: PermissionMode = .acceptEdits {
        didSet { save() }
    }
    var allowDangerouslySkipPermissions: Bool = false {
        didSet {
            if !allowDangerouslySkipPermissions && initialPermissionMode == .bypassPermissions {
                initialPermissionMode = .acceptEdits
            }
            save()
        }
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

        if let mode = dict["claudeCode.initialPermissionMode"] as? String,
           let pm = PermissionMode(rawValue: mode) {
            initialPermissionMode = pm
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
        logger.info("Loaded settings: permissionMode=\(self.initialPermissionMode.rawValue, privacy: .public)")
    }

    private func save() {
        let dict: [String: Any] = [
            "claudeCode.initialPermissionMode": initialPermissionMode.rawValue,
            "claudeCode.allowDangerouslySkipPermissions": allowDangerouslySkipPermissions,
            "claudeCode.useCtrlEnterToSend": useCtrlEnterToSend,
            "claudeCode.respectGitIgnore": respectGitIgnore,
        ]
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
