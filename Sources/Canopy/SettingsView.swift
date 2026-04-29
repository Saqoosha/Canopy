import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            RemoteSettingsTab()
                .tabItem { Label("Remote", systemImage: "network") }
        }
        .frame(width: 460)
        .fixedSize()
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
        }
        .formStyle(.grouped)
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
    @State private var sshHosts: [String] = SSHHostStore.hosts()

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
            } footer: {
                SettingsFooter(text: "Hosts you've connected to from the launcher are remembered here for quick reuse.")
            }
        }
        .formStyle(.grouped)
        // SSHHostStore is a UserDefaults-backed namespace, not @Observable, so
        // additions made elsewhere (launcher) don't propagate live. Refresh
        // whenever the tab becomes active so the list stays current.
        .onAppear { sshHosts = SSHHostStore.hosts() }
    }
}
