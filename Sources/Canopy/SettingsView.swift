import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "server.rack") }

            ClaudeAccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            // MacroPad and Sharing are whole features, not stray preferences,
            // and General had grown to eleven controls carrying both. General
            // is for the small toggles with nowhere else to live.
            MacroPadSettingsTab()
                .tabItem { Label("MacroPad", systemImage: "keyboard") }

            // Sharing is this Mac serving others (phone and other Macs alike);
            // Remote is this Mac reaching other machines (SSH hosts, paired Macs).
            SharingSettingsTab()
                .tabItem { Label("Sharing", systemImage: "dot.radiowaves.left.and.right") }

            RemoteSettingsTab()
                .tabItem { Label("Remote", systemImage: "network") }
        }
        // Resizable: the grouped Forms scroll, so any height above the
        // minimum works, and the relay URL and footers want the width.
        .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity,
               minHeight: 320, idealHeight: 616, maxHeight: .infinity)
        .background(ResizableWindowEnabler())
    }
}

/// SwiftUI's `Settings` scene creates its window without `.resizable` in the
/// style mask, and `.windowResizability` does not add it, so the frame's
/// max-size alone leaves the window fixed. Insert it once the view is in a window.
///
/// It also owns the window's size across launches. AppKit's autosave does
/// write `NSWindow Frame com_apple_SwiftUI_Settings_window`, but SwiftUI then
/// sizes the window to the content's ideal size, so only the position survived.
/// The size is saved at the end of a user's live resize only — SwiftUI's own
/// programmatic resizes also fire `didResize` and would overwrite it with the
/// ideal size — and re-applied one runloop turn after attach, past SwiftUI's sizing.
private struct ResizableWindowEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Host() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Host: NSView {
        private static let sizeKey = "canopy.settingsWindowSize"
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
            guard let window else { return }
            window.styleMask.insert(.resizable)

            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: Self.sizeKey)
                }
            }

            guard let saved = UserDefaults.standard.string(forKey: Self.sizeKey) else { return }
            let size = NSSizeFromString(saved)
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                var frame = window.frame
                // Keep the top-left corner where AppKit's autosave put it.
                frame.origin.y += frame.height - size.height
                frame.size = size
                // A size saved on a larger display must still fit this one.
                if let visible = window.screen?.visibleFrame {
                    frame.size.width = min(frame.width, visible.width)
                    frame.size.height = min(frame.height, visible.height)
                    frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                    frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                }
                window.setFrame(frame, display: true)
            }
        }
    }
}

/// Footer text that mirrors macOS System Settings: small, secondary, always
/// left-aligned. macOS 15 SwiftUI's grouped Form otherwise right-aligns footer
/// Text under control rows, which visually disconnects the footer from the
/// section's leading edge.
private struct SettingsFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable private var settings = CanopySettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Use Ctrl+Enter to send", isOn: $settings.useCtrlEnterToSend)
            } footer: {
                SettingsFooter(text: "Takes effect on the next session.")
            }

            Section {
                Toggle("Respect .gitignore in file search", isOn: $settings.respectGitIgnore)
            } footer: {
                SettingsFooter(text: "Applies immediately to @-mention file search.")
            }

            Section {
                Toggle("Show session recap after being away", isOn: $settings.recapEnabled)
            } footer: {
                SettingsFooter(text: "After Canopy sits in the background for 3 minutes, each visible pane summarises where its session left off. Costs a small model call per pane.")
            }

            Section {
                Toggle("Keep idle sessions' cache warm", isOn: $settings.keepAliveEnabled)
                Toggle("Copy ignored build files into new worktrees", isOn: $settings.seedWorktreeArtifacts)
            } footer: {
                SettingsFooter(text: "Every 55 minutes, each open pane that has gone quiet sends a short message and gets a one-word reply, so its conversation stays cached. Rebuilding a lapsed cache costs about 20x more than keeping one warm, so returning to a session left overnight is cheaper with this on. Each refresh stays in that conversation's history. Close a pane to stop refreshing it."
                    )
            }


        }
        .formStyle(.grouped)
    }


}

// MARK: - MacroPad

/// The USB/bridge key pad. Its own tab because it is four controls about one
/// piece of hardware, and because none of them mean anything to someone
/// without a pad — they were the bulk of what made General unreadable.
private struct MacroPadSettingsTab: View {
    @Bindable private var settings = CanopySettings.shared

    var body: some View {
        Form {
            Section {
                Picker("MacroPad", selection: Binding(
                    get: { settings.macroPadSource.rawValue },
                    set: { raw in
                        switch raw {
                        case "off":
                            settings.macroPadSource = .off
                        case "remote":
                            // Unreachable while the row is absent from the
                            // menu (see the conditional row below), but the
                            // Picker's setter is not the place to trust that.
                            if let endpoint = MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost) {
                                settings.macroPadSource = .remote(endpoint)
                            }
                        default:
                            settings.macroPadSource = .local
                        }
                    }
                )) {
                    Text("Off").tag("off")
                    Text("Local USB").tag("local")
                    // `.disabled` on an individual Picker row is a no-op for
                    // this Picker's rendering (AXPopUpButton menu item stayed
                    // enabled and selectable, measured via the accessibility
                    // tree) — a conditional row is what actually keeps this
                    // choice off the menu. Safe because the selection can
                    // never *be* `remote` with an unusable address, though
                    // not by one mechanism: `CanopySettings.load` degrades
                    // that case to `.off`, `commitHost` moves it to `.off`
                    // too when the field is cleared to empty, and for a
                    // non-empty-but-unparseable edit `commitHost` sets
                    // `hostError` and returns without touching
                    // `macroPadSource` at all — every write site validates
                    // before ever assigning `.remote`, so the invariant holds
                    // without that branch needing to reach for `.off` itself.
                    if MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost) != nil {
                        Text("Remote bridge").tag("remote")
                    }
                }

                LabeledContent("Bridge address") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $hostDraft, prompt: Text("mbp or mbp:8765"))
                            .textFieldStyle(.roundedBorder)
                            .focused($hostFieldFocused)
                            .onChange(of: hostDraft) { _, newValue in
                                // While the source isn't already `.remote`,
                                // mirror a parseable (or emptied) draft in
                                // live so the Picker's "Remote bridge" row
                                // can appear as the address becomes valid,
                                // rather than staying hidden until commit.
                                // See `liveHostUpdate`'s doc for why a LIVE
                                // `.remote` selection is excluded, and why an
                                // unparseable draft stores nothing.
                                guard let stored = MacroPadRemoteEndpoint.liveHostUpdate(
                                    source: settings.macroPadSource,
                                    draft: newValue
                                ) else { return }
                                settings.macroPadRemoteHost = stored
                                // The user has visibly fixed it; a half-typed
                                // draft never sets this in the first place.
                                if MacroPadRemoteEndpoint.parse(stored) != nil { hostError = nil }
                            }
                            .onSubmit { commitHost() }
                            .onChange(of: hostFieldFocused) { _, focused in
                                // Committing per keystroke would try to
                                // connect to "m", then "mb", then "mbp",
                                // tearing down the link each time — this is
                                // what still applies while the source is
                                // already `.remote`, since the live update
                                // above excludes that case.
                                if !focused { commitHost() }
                            }
                        if let hostError {
                            Text(hostError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent("LED brightness") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(settings.macroPadBrightness) },
                                              set: { settings.macroPadBrightness = Int($0.rounded()) }),
                               in: 0...100, step: 5)
                        Text("\(settings.macroPadBrightness)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(settings.macroPadSource.isOff)

                Toggle("Pad is rotated 180°", isOn: $settings.macroPadReversed)
                    .disabled(settings.macroPadSource.isOff)
            } footer: {
                SettingsFooter(text: "Lights each pane's activity on the pad's keys, and switches panes when a key is pressed. Local USB connects automatically when the pad is plugged in; Remote bridge reaches a pad on another Mac running scripts/macropad-bridge.sh. A small indicator at the bottom of the sidebar shows the link state, and clicking it switches source without coming here. Turn on \"Pad is rotated 180°\" when the pad is mounted upside-down relative to its printed key order, so the leftmost pane lights and answers on the key that now looks leftmost.")
            }
            .onAppear { hostDraft = settings.macroPadRemoteHost }
        }
        .formStyle(.grouped)
    }

    @State private var hostDraft: String = ""
    @State private var hostError: String?
    @FocusState private var hostFieldFocused: Bool

    /// Validates at the boundary so nothing downstream ever re-parses. An
    /// unparseable value is refused rather than stored — the settings file is
    /// the only other way in, and `CanopySettings.load` re-validates that.
    private func commitHost() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespaces)
        hostDraft = trimmed

        guard !trimmed.isEmpty else {
            hostError = nil
            settings.macroPadRemoteHost = ""
            // The selector cannot stay on a source with no address. It moves
            // to `.off`, never `.local` — silently connecting to a different
            // pad than the one configured is the worst outcome available.
            if case .remote = settings.macroPadSource { settings.macroPadSource = .off }
            return
        }
        guard let endpoint = MacroPadRemoteEndpoint.parse(trimmed) else {
            hostError = "Use host or host:port, e.g. mbp:8765."
            return
        }
        hostError = nil
        settings.macroPadRemoteHost = trimmed
        // Re-resolve a live remote selection so an edited port takes effect
        // without a second trip through the Picker.
        if case .remote = settings.macroPadSource { settings.macroPadSource = .remote(endpoint) }
    }
}

// MARK: - Sharing

/// This Mac serving others: the roster it publishes to the relay, the name and
/// secret that identify it there, and the live mirror that lets a phone or
/// another Mac open its sessions. Pairing with other Macs is the consuming
/// side and lives in Remote.
private struct SharingSettingsTab: View {
    @Bindable private var settings = CanopySettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Publish this Mac's panes", isOn: $settings.rosterEnabled)
                TextField("Relay URL", text: $settings.rosterEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.rosterEnabled)
                TextField("This Mac's name", text: $settings.machineDisplayName,
                          prompt: Text(MachineIdentity.defaultDisplayName()))
                    .textFieldStyle(.roundedBorder)
                SecureField("Relay secret", text: $relaySecret)
                    .textFieldStyle(.roundedBorder)
                    .focused($relaySecretFocused)
                    .onSubmit { commitRelaySecret() }
                    .onChange(of: relaySecretFocused) { _, focused in
                        // Clicking away must commit too, not just Return —
                        // otherwise a typed secret that the user tabs past
                        // is silently discarded with no feedback.
                        if !focused { commitRelaySecret() }
                    }
                // Never reads the secret back into the field (a SecureField
                // bound to a Keychain read would defeat the point of a
                // SecureField) — this is the only signal the field gives
                // about whether anything is actually stored.
                Text(hasStoredSecret ? "A secret is stored." : "No secret stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Shown on the phone and on other Macs. Leave empty to use the Mac's own name. The secret is kept in the Keychain, not in settings.json — that file is plaintext and is shared with the installed Release build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Relay")
            }
            .onAppear { hasStoredSecret = MachineIdentity.hasRelaySecret() }

            Section {
                Toggle("Let other devices open live sessions", isOn: $settings.mirrorEnabled)
                LabeledContent("Status", value: mirrorStatusText)
                HStack {
                    Button("Copy Connection") { copyMirrorConnection() }
                        .disabled(listeningAddress == nil)
                    Button("Reset Password") { resetMirrorPassword() }
                        .disabled(!settings.mirrorEnabled)
                    Spacer()
                    if let mirrorNotice {
                        Text(mirrorNotice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Live mirror")
            } footer: {
                SettingsFooter(text: "Paste it into the iPhone app's Settings, or into another Mac's Settings › Remote › Other Macs. It contains the password: anyone on your tailnet who has it can read and drive this Mac's sessions. Reset the password to disconnect every phone and refuse every copy made before.")
            }
        }
        .formStyle(.grouped)
    }

    @State private var mirrorStatus = MirrorServerStatus.shared
    @State private var mirrorNotice: String?

    private var listeningAddress: (host: String, port: UInt16)? {
        if case .listening(let host, let port) = mirrorStatus.state { return (host, port) }
        return nil
    }

    private var mirrorStatusText: String {
        switch mirrorStatus.state {
        case .off: "Off"
        case .noTailscale: "No Tailscale address on this Mac"
        case .noPassword: "Cannot create the password in the Keychain"
        case .listening(let host, let port): "Listening on \(host):\(port)"
        case .failed(let reason): "Cannot listen: \(reason)"
        }
    }

    private func copyMirrorConnection() {
        guard let address = listeningAddress else { return }
        guard let token = MirrorAccess.token(createIfMissing: true) else {
            mirrorNotice = "Cannot read the password from the Keychain"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MirrorAccess.connectionString(host: address.host, port: address.port, token: token, machine: MachineIdentity.stableId() ?? ""), forType: .string)
        mirrorNotice = "Copied"
    }

    private func resetMirrorPassword() {
        mirrorNotice = MirrorServer.resetPassword()
            ? "Password reset; copy the connection again"
            : "Reset failed; the old password is still in force"
    }

    @State private var relaySecret: String = ""
    @FocusState private var relaySecretFocused: Bool
    @State private var hasStoredSecret: Bool = false

    /// A blank submit (the natural result of tabbing through with the
    /// never-seeded, always-blank-looking SecureField untouched) must be a
    /// no-op, never a delete — `MachineIdentity.storeRelaySecret` already
    /// guards that on its own end; this just keeps the indicator in sync
    /// whichever way the guard resolves. Storing alone is not enough because
    /// the Keychain is not observable — tell the roster publisher so it reconnects.
    private func commitRelaySecret() {
        MachineIdentity.storeRelaySecret(relaySecret)
        hasStoredSecret = MachineIdentity.hasRelaySecret()
        RosterPublisher.current?.secretChanged()
    }
}

// MARK: - Permissions

private struct PermissionsSettingsTab: View {
    @Bindable private var settings = CanopySettings.shared

    // Mirrors LauncherView's Permission picker. The matching invariant — that
    // defaultPermissionMode never persists as .bypassPermissions while the
    // opt-in is off — is enforced by CanopySettings.allowDangerouslySkipPermissions
    // in didSet + load(). Filtering here only governs what the Picker shows.
    private var visiblePermissionModes: [PermissionMode] {
        PermissionMode.allCases.filter { mode in
            mode != .bypassPermissions || settings.allowDangerouslySkipPermissions
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow Bypass Permissions mode", isOn: $settings.allowDangerouslySkipPermissions)
            } footer: {
                SettingsFooter(text: "When enabled, “Bypass All” appears in the launcher's Permission picker.")
            }

            Section {
                Picker("Default for Recents", selection: $settings.defaultPermissionMode) {
                    ForEach(visiblePermissionModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } footer: {
                SettingsFooter(text: "Used when reopening a recent session from the sidebar (local or teleported cloud). The Launcher tracks its own per-session selection separately.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Remote

private struct RemoteSettingsTab: View {
    @Bindable private var settings = CanopySettings.shared
    @State private var sshHosts: [String] = SSHHostStore.hosts()
    @State private var peerNotice: String?

    var body: some View {
        Form {
            Section {
                if sshHosts.isEmpty {
                    Text("No saved hosts. Add one from the launcher.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(sshHosts, id: \.self) { host in
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(host)
                            Spacer()
                            Button(role: .destructive) {
                                SSHHostStore.remove(host)
                                sshHosts = SSHHostStore.hosts()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove host")
                        }
                    }
                }
            } header: {
                Text("SSH Hosts")
            } footer: {
                SettingsFooter(text: "Hosts you've connected to from the launcher are remembered here for quick reuse.")
            }

            Section {
                if settings.mirrorPeers.isEmpty {
                    Text("No other Macs paired.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.mirrorPeers.keys.sorted(), id: \.self) { machine in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peerName(machine))
                            Text(settings.mirrorPeers[machine] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { forgetPeer(machine) }
                    }
                }
                HStack {
                    Button("Paste Connection from Mac") { pastePeerConnection() }
                    Spacer()
                    if let peerNotice {
                        Text(peerNotice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Other Macs")
            } footer: {
                SettingsFooter(text: "On the other Mac, turn on Settings › Sharing › Live mirror and use Copy Connection; then paste here. Its sessions appear in this Mac's sidebar once both Macs publish to the same relay.")
            }
        }
        .formStyle(.grouped)
        // SSHHostStore is a UserDefaults-backed namespace, not @Observable, so
        // additions made elsewhere (launcher) don't propagate live. Refresh
        // whenever the tab becomes active so the list stays current.
        .onAppear { sshHosts = SSHHostStore.hosts() }
    }

    private func peerName(_ machine: String) -> String {
        SessionStore.shared?.remoteRosters[machine]?.displayName ?? machine
    }

    private func pastePeerConnection() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let connection = MirrorAccess.parseConnectionString(text) else {
            peerNotice = "That is not a Canopy connection (expected canopy-mirror://…)."
            return
        }
        if connection.machineId == MachineIdentity.stableId() {
            peerNotice = "That is this Mac's own connection."
            return
        }
        guard MirrorAccess.storePeerToken(connection.token, machineId: connection.machineId) else {
            peerNotice = "Could not store the password in the Keychain."
            return
        }
        settings.mirrorPeers[connection.machineId] = "\(connection.host):\(connection.port)"
        peerNotice = "Paired with \(peerName(connection.machineId))."
    }

    private func forgetPeer(_ machine: String) {
        MirrorAccess.forgetPeerToken(machineId: machine)
        settings.mirrorPeers[machine] = nil
        peerNotice = nil
    }
}

// MARK: - Providers

private struct ProvidersSettingsTab: View {
    @State private var providers: [ModelProvider] = ModelProviderStore.load()
    @State private var selectedId: String = ModelProviderStore.selectedId()
    @State private var editProvider = ModelProvider()
    @State private var showEditSheet = false
    @State private var isEditingExisting = false

    var body: some View {
        Form {
            Section {
                if providers.isEmpty {
                    Text("No providers configured. Add one to use non-Anthropic APIs in the launcher.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(providers) { provider in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.body.weight(.medium))
                                Text(provider.baseURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if provider.id == selectedId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                            Button {
                                editProvider = provider
                                isEditingExisting = true
                                showEditSheet = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit provider")
                            Button(role: .destructive) {
                                ModelProviderStore.delete(provider.id)
                                providers = ModelProviderStore.load()
                                selectedId = ModelProviderStore.selectedId()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove provider")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            ModelProviderStore.select(provider.id)
                            selectedId = provider.id
                        }
                    }
                }
            } header: {
                Text("Model Providers")
            } footer: {
                SettingsFooter(text: "Select a provider to use for new sessions. The launcher picker shows the selected provider by default. \"Anthropic (default)\" means no custom API is used.")
            }

            Section {
                Menu("Add from Template…") {
                    ForEach(ModelProvider.templates) { template in
                        Button(template.name) {
                            editProvider = ModelProvider(from: template)
                            isEditingExisting = false
                            showEditSheet = true
                        }
                    }
                }
                Button("Add Custom…") {
                    editProvider = ModelProvider()
                    isEditingExisting = false
                    showEditSheet = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ModelProviderStore.migrateIfNeeded()
            providers = ModelProviderStore.load()
            selectedId = ModelProviderStore.selectedId()
        }
        .sheet(isPresented: $showEditSheet) {
            ProviderEditView(provider: $editProvider) {
                let p = editProvider
                if isEditingExisting {
                    if let idx = providers.firstIndex(where: { $0.id == p.id }) {
                        var updated = providers
                        updated[idx] = p
                        ModelProviderStore.save(updated)
                    }
                } else {
                    providers.append(p)
                    ModelProviderStore.save(providers)
                    if providers.count == 1 {
                        ModelProviderStore.select(p.id)
                        selectedId = p.id
                    }
                }
                providers = ModelProviderStore.load()
                showEditSheet = false
            } onCancel: {
                showEditSheet = false
            }
        }
    }
}

// MARK: - Claude Accounts

private struct ClaudeAccountsSettingsTab: View {
    @State private var accounts: [ClaudeAccount] = ClaudeAccountStore.load()
    @State private var defaultId: String = ClaudeAccountStore.defaultAccountId()
    @State private var newName: String = ""
    @State private var newConfigDir: String = ""

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ClaudeAccountStore.normalizedConfigDir(newConfigDir) != nil
    }

    var body: some View {
        Form {
            Section {
                if accounts.isEmpty {
                    Text("No extra accounts yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.body.weight(.medium))
                                Text(account.configDir)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                ClaudeAccountStore.delete(account.id)
                                accounts = ClaudeAccountStore.load()
                                defaultId = ClaudeAccountStore.defaultAccountId()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove account")
                        }
                    }
                }
            } header: {
                Text("Claude Accounts")
            } footer: {
                SettingsFooter(text: "Extra Claude logins. Each one is a separate CLAUDE_CONFIG_DIR that shares your settings, hooks and transcripts with the default login. Log in once in Terminal: CLAUDE_CONFIG_DIR=<dir> claude, then /login.")
            }

            Section {
                TextField("Name", text: $newName)
                TextField("Config directory", text: $newConfigDir, prompt: Text("~/.claude-alt"))
                Button("Add") {
                    guard let dir = ClaudeAccountStore.normalizedConfigDir(newConfigDir) else { return }
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    var updated = accounts
                    updated.append(ClaudeAccount(name: name, configDir: dir))
                    ClaudeAccountStore.save(updated)
                    accounts = ClaudeAccountStore.load()
                    newName = ""
                    newConfigDir = ""
                }
                .disabled(!canAdd)
            }

            Section {
                Picker("New sessions use", selection: Binding(
                    get: { defaultId },
                    set: { newValue in
                        defaultId = newValue
                        ClaudeAccountStore.setDefault(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("Default login").tag("")
                    ForEach(accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accounts = ClaudeAccountStore.load()
            defaultId = ClaudeAccountStore.defaultAccountId()
        }
    }
}

private struct ProviderEditView: View {
    @Binding var provider: ModelProvider
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(provider.name.isEmpty ? "New Provider" : provider.name)
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if provider.name.isEmpty {
                        provider.name = "Untitled"
                    }
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()

            Divider()

            ScrollView {
                Form {
                    Section {
                        TextField("Name", text: $provider.name, prompt: Text("e.g. DeepSeek"))
                        TextField("Base URL", text: $provider.baseURL, prompt: Text("https://api.deepseek.com/anthropic"))
                            .font(.callout.monospaced())
                        SecureField("Auth Token", text: $provider.authToken, prompt: Text("API key or $ENV_VAR"))
                            .font(.callout.monospaced())
                    }

                    Section("Model Mapping") {
                        TextField("Opus", text: $provider.opusModel, prompt: Text("deepseek-v4-pro[1m]"))
                            .font(.callout.monospaced())
                        TextField("Sonnet", text: $provider.sonnetModel, prompt: Text("deepseek-v4-pro[1m]"))
                            .font(.callout.monospaced())
                        TextField("Haiku", text: $provider.haikuModel, prompt: Text("deepseek-v4-flash"))
                            .font(.callout.monospaced())
                        TextField("Subagent", text: $provider.subagentModel, prompt: Text("deepseek-v4-flash"))
                            .font(.callout.monospaced())
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 420)
        .fixedSize()
    }

}
