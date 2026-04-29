import SwiftUI

struct SettingsView: View {
    @Bindable var settings = CanopySettings.shared
    @State private var sshHosts: [String] = SSHHostStore.hosts()

    private var visiblePermissionModes: [PermissionMode] {
        // Hide bypass unless the user has explicitly opted in — keeps the
        // dropdown short and matches the launcher's existing behaviour.
        PermissionMode.allCases.filter { mode in
            mode != .bypassPermissions || settings.allowDangerouslySkipPermissions
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow Bypass Permissions Mode", isOn: $settings.allowDangerouslySkipPermissions)
            } footer: {
                Text("When enabled, \"Bypass All\" appears in the launcher's Permission picker.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default for Recents", selection: $settings.defaultPermissionMode) {
                    ForEach(visiblePermissionModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Permission Mode")
            } footer: {
                Text("Used when reopening a recent session from the sidebar (local or teleported cloud). The Launcher tracks its own per-session selection separately.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use Ctrl+Enter to Send", isOn: $settings.useCtrlEnterToSend)
            } footer: {
                Text("Takes effect on next session.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Respect .gitignore in File Search", isOn: $settings.respectGitIgnore)
            } footer: {
                Text("Takes effect immediately for @-mention file search.")
                    .foregroundStyle(.secondary)
            }

            Section("SSH Hosts") {
                ForEach(sshHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(role: .destructive) {
                            SSHHostStore.remove(host)
                            sshHosts = SSHHostStore.hosts()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if sshHosts.isEmpty {
                    Text("No saved hosts. Add one from the launcher.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize()
    }
}
