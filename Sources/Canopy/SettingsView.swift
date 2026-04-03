import SwiftUI

struct SettingsView: View {
    @Bindable var settings = CanopySettings.shared
    @State private var sshHosts: [String] = SSHHostStore.hosts()

    var body: some View {
        Form {
            Section {
                Toggle("Allow Bypass Permissions Mode", isOn: $settings.allowDangerouslySkipPermissions)
            } footer: {
                Text("When enabled, \"Bypass All\" appears in the launcher's Permission picker.")
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
