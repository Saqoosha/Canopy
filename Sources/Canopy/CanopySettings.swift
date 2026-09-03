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
    /// Generate a "what were we doing" recap for idle sessions while Canopy
    /// sits in the background (see `RecapCoordinator`). Mirrors the CLI's
    /// `awaySummaryEnabled` / `/config` → `recap` preference. Costs one
    /// small model call per session per return, so it's user-disableable.
    var recapEnabled: Bool = true {
        didSet { save() }
    }
    /// Keep each open pane's prompt cache warm while the user is away
    /// (see `KeepAliveCoordinator`).
    ///
    /// Defaults on, unlike a typical "spends money" toggle, because it
    /// spends money only to avoid spending more: a refresh costs a small
    /// fraction of the cache write it prevents (see `KeepAliveCoordinator`
    /// for the ratio, why it depends on the model, and the one refresh it
    /// does not describe), so any session the user returns to is cheaper
    /// with this on. The toggle exists for the case
    /// the arithmetic cannot cover — sessions parked and never resumed,
    /// where every refresh is pure loss.
    var keepAliveEnabled: Bool = true {
        didSet { save() }
    }
    /// Which pad this Canopy drives: none, the local USB one, or a bridge on
    /// another Mac. Replaces the old `macroPadEnabled` boolean, which is read
    /// once at load for migration and then never written again.
    ///
    /// Only one is ever live. Switching away releases the port, and the
    /// firmware blanks itself on host disconnect, so the pad left behind goes
    /// dark with no code and no user action.
    var macroPadSource: MacroPadSource = .local {
        didSet { save() }
    }

    /// Address of the remote bridge, as the user typed it (`mbp`, `mbp:8765`).
    /// Kept separate from `macroPadSource` so the menu can switch to remote
    /// and back without the address having to be re-entered.
    ///
    /// Stored raw rather than as a parsed endpoint because this is also what
    /// the Settings field shows; it is validated on commit there, and
    /// re-validated at load in case the JSON was edited by hand.
    var macroPadRemoteHost: String = "" {
        didSet { save() }
    }
    /// Whether the pad is mounted rotated 180°, so the key that used to be
    /// first is now last. Reverses BOTH data-flow directions at once — the
    /// LED a pane lights and the pane a key focuses — because both ask
    /// `MacroPadController.paneIndex(forKey:keyCount:reversed:)` the same
    /// key→pane question (the LED loop is written that way round too), and a
    /// pad whose lights and keys disagreed would be worse than either
    /// orientation.
    ///
    /// The reversal is over the pad's whole key count, not over the pane
    /// count: pane *p* stays on key `keyCount - 1 - p` however many panes are
    /// open, instead of the whole block sliding as panes open and close.
    var macroPadReversed: Bool = false {
        didSet { save() }
    }
    /// Global LED brightness 0–100. The firmware multiplies this into every
    /// channel, so colors are sent full-scale and this is the only dimming
    /// knob — pre-dimming a color would dim it twice.
    ///
    /// 60 rather than something dimmer because the darkest colour on the pad
    /// has to survive the multiply — see `SessionActivity.ledColor`, which
    /// owns that arithmetic. Two things follow that are easy to miss: idle's
    /// white balance was measured *at this brightness*, so a large change here
    /// re-opens it; and the firmware has its own reason for the same number
    /// (a deep pulse runs out of distinct levels near its floor below it).
    var macroPadBrightness: Int = 60 {
        didSet {
            let clamped = min(100, max(0, macroPadBrightness))
            if clamped != macroPadBrightness {
                macroPadBrightness = clamped
                return // the re-entrant didSet saves
            }
            save()
        }
    }
    /// Default permission mode used when the sidebar reopens a recent
    /// session (closed local row or closed cloud / teleport row). The
    /// Launcher view tracks its own per-session selection separately —
    /// this preference only governs sessions resumed via a single click.
    var defaultPermissionMode: PermissionMode = .acceptEdits {
        didSet { save() }
    }

    /// Shown in the phone's roster and, later, in notification text. Empty
    /// means "use the Mac's own name" — see `MachineIdentity`.
    var machineDisplayName: String = "" {
        didSet { save() }
    }

    /// Off by default. Publishing dials out to a third-party endpoint, so it
    /// is opt-in the way `allowDangerouslySkipPermissions` is.
    var rosterEnabled: Bool = false {
        didSet { save() }
    }

    /// The relay's base URL, e.g. `https://canopy-mobile-relay.example.workers.dev`.
    var rosterEndpoint: String = "" {
        didSet { save() }
    }

    let filePath: URL

    /// Suppresses `save()` while `load()` is assigning. Every property's
    /// `didSet` calls `save()`, and `save()` writes EVERY key from memory —
    /// so before this, loading `canopy.macroPadReversed` (line 1 of many)
    /// wrote the not-yet-loaded default of `canopy.defaultPermissionMode` to
    /// disk, and only the later assignment's own `save()` repaired it. The
    /// repair was by adjacency, not by construction: a write failure or a
    /// future early return between the two would have left the user's
    /// permission mode replaced by the default. `load()` now writes once, at
    /// the end, which also keeps the legacy-key retirement in `save()` firing
    /// on the first launch after a migration rather than on the next edit.
    private var isLoading = false

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let canopyDir = appSupport.appendingPathComponent("Canopy")
        self.filePath = canopyDir.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        isLoading = true
        // `defer` and not a plain assignment at the end: the guard below
        // returns early on a missing or unparseable file.
        defer { isLoading = false }
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
        if let recap = dict["canopy.recapEnabled"] as? Bool {
            recapEnabled = recap
        }
        if let keepAlive = dict["canopy.keepAliveEnabled"] as? Bool {
            keepAliveEnabled = keepAlive
        }
        let storedSourceRaw = dict["canopy.macroPadSource"] as? String
        macroPadRemoteHost = (dict["canopy.macroPadRemoteHost"] as? String) ?? ""
        macroPadSource = MacroPadSource.migrated(
            storedRaw: storedSourceRaw,
            storedHost: macroPadRemoteHost,
            legacyEnabled: dict["canopy.macroPadEnabled"] as? Bool
        )
        // `resolve` degrades a `remote` selector with an unusable stored
        // host to `.off` silently — by design, since `resolve` is pure and
        // probe-reached. This is the one place that can say something about
        // it: settings.json is hand-editable (see the doc comment on
        // `macroPadRemoteHost`), and without this a hand edit that broke the
        // address would leave MacroPad silently off next launch with no
        // trail explaining why.
        if storedSourceRaw == "remote", macroPadSource.isOff {
            logger.notice("MacroPad: stored source was \"remote\" but canopy.macroPadRemoteHost could not be parsed; falling back to Off")
        }
        if let reversed = dict["canopy.macroPadReversed"] as? Bool {
            macroPadReversed = reversed
        } else if dict["canopy.macroPadReversed"] != nil {
            // Same reasoning as the `remote` fallback above: settings.json is
            // hand-editable, and the next save overwrites the bad value with
            // the default, so without this the edit vanishes with no trail.
            logger.notice("MacroPad: canopy.macroPadReversed is not a boolean; ignoring it and keeping \(self.macroPadReversed, privacy: .public)")
        }
        if let brightness = dict["canopy.macroPadBrightness"] as? Int { macroPadBrightness = min(100, max(0, brightness)) }
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
        if let name = dict["canopy.machineDisplayName"] as? String {
            machineDisplayName = name
        }
        if let rosterOn = dict["canopy.rosterEnabled"] as? Bool {
            rosterEnabled = rosterOn
        }
        if let endpoint = dict["canopy.rosterEndpoint"] as? String {
            rosterEndpoint = endpoint
        }
        // Re-clamp on load: if a stale settings.json paired bypass with a
        // disabled opt-in (manual edit, downgrade, etc.) the launcher
        // Picker would silently drop bypass while the recents default
        // kept it. Force them back into sync.
        if !allowDangerouslySkipPermissions, defaultPermissionMode == .bypassPermissions {
            defaultPermissionMode = .acceptEdits
        }
        logger.info("Loaded settings: allowBypass=\(self.allowDangerouslySkipPermissions, privacy: .public)")
        // One write for the whole load, after every value is in place, so any
        // migration or clamp above reaches disk without the intermediate
        // states doing so first.
        isLoading = false
        save()
    }

    private func save() {
        guard !isLoading else { return }
        var dict = loadCurrentDict()
        dict["claudeCode.allowDangerouslySkipPermissions"] = allowDangerouslySkipPermissions
        dict["claudeCode.useCtrlEnterToSend"] = useCtrlEnterToSend
        dict["claudeCode.respectGitIgnore"] = respectGitIgnore
        dict["canopy.recapEnabled"] = recapEnabled
        dict["canopy.keepAliveEnabled"] = keepAliveEnabled
        dict["canopy.macroPadSource"] = macroPadSource.rawValue
        dict["canopy.macroPadRemoteHost"] = macroPadRemoteHost
        // Retire the pre-source key on the first save after migration.
        // Assigning nil removes it, so a downgrade sees a fresh install
        // rather than a stale boolean fighting the selector.
        dict["canopy.macroPadEnabled"] = nil
        dict["canopy.macroPadReversed"] = macroPadReversed
        dict["canopy.macroPadBrightness"] = macroPadBrightness
        dict["canopy.defaultPermissionMode"] = defaultPermissionMode.rawValue
        dict["canopy.machineDisplayName"] = machineDisplayName
        dict["canopy.rosterEnabled"] = rosterEnabled
        dict["canopy.rosterEndpoint"] = rosterEndpoint
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
