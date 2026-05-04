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

            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "server.rack") }
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
