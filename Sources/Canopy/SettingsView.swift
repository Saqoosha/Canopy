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
        .scenePadding()
        .frame(width: 500, height: 320)
    }
}

/// Footer text that mirrors macOS System Settings: small, secondary,
/// always left-aligned. SwiftUI's grouped Form on macOS otherwise
/// right-aligns footer Text under control rows, which looks wrong.
private struct SettingsFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var settings = CanopySettings.shared

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
    @Bindable var settings = CanopySettings.shared

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
                Text("Saved SSH Hosts")
            } footer: {
                SettingsFooter(text: "Hosts you've connected to from the launcher are remembered here for quick reuse.")
            }
        }
        .formStyle(.grouped)
    }
}
