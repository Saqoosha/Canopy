import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopySettings")

@Observable
final class CanopySettings {
    nonisolated(unsafe) static let shared = CanopySettings()

    var allowDangerouslySkipPermissions: Bool = false {
        didSet {
            // Toggling the opt-in off must also clamp the recents default
            // away from `.bypassPermissions`; otherwise sidebar reopens
            // would keep launching with bypass while the launcher Picker
            // hides that mode (UI / behavior would diverge).
            if !allowDangerouslySkipPermissions, defaultPermissionMode == .bypassPermissions {
                defaultPermissionMode = .acceptEdits
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
    /// Default permission mode used when the sidebar reopens a recent
    /// session (closed local row or closed cloud / teleport row). The
    /// Launcher view tracks its own per-session selection separately —
    /// this preference only governs sessions resumed via a single click.
    var defaultPermissionMode: PermissionMode = .acceptEdits {
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
        if let raw = dict["canopy.defaultPermissionMode"] as? String,
           let mode = PermissionMode(rawValue: raw)
        {
            defaultPermissionMode = mode
        } else if let legacy = UserDefaults.standard.string(forKey: "launcher.permissionMode"),
                  let migrated = PermissionMode(rawValue: legacy)
        {
            // First run after the preference moved into settings.json — seed
            // it from the launcher's last picker value so existing users
            // don't get a surprise "acceptEdits" default for recents.
            defaultPermissionMode = migrated
        }
        // Re-clamp on load: if a stale settings.json paired bypass with a
        // disabled opt-in (manual edit, downgrade, etc.) the launcher
        // Picker would silently drop bypass while the recents default
        // kept it. Force them back into sync.
        if !allowDangerouslySkipPermissions, defaultPermissionMode == .bypassPermissions {
            defaultPermissionMode = .acceptEdits
        }
        logger.info("Loaded settings: allowBypass=\(self.allowDangerouslySkipPermissions, privacy: .public)")
    }

    private func save() {
        var dict = loadCurrentDict()
        dict["claudeCode.allowDangerouslySkipPermissions"] = allowDangerouslySkipPermissions
        dict["claudeCode.useCtrlEnterToSend"] = useCtrlEnterToSend
        dict["claudeCode.respectGitIgnore"] = respectGitIgnore
        dict["canopy.defaultPermissionMode"] = defaultPermissionMode.rawValue
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
