import SwiftUI

struct LauncherView: View {
    @Bindable var appState: AppState

    @State private var selectedDirectory: URL?
    @State private var recentDirectories: [URL] = []
    @State private var sessions: [SessionEntry] = []
    @State private var searchText = ""
    @State private var hoveredDirectoryPath: String?
    @State private var hoveredSessionId: String?
    @State private var isDropTargeted = false
    @State private var remoteHost: String = ""
    @State private var savedHosts: [String] = []
    @State private var isRemoteMode = false
    @State private var remoteDirectory: String = "~"
    @State private var showRemoteBrowser = false
    @State private var updater = ExtensionUpdater()

    @AppStorage("launcher.model") private var model = ""
    @AppStorage("launcher.effortLevel") private var effortLevel = ""
    @AppStorage("launcher.permissionMode") private var permissionModeRaw = "acceptEdits"

    private static let modelOptions = ["", "opus", "sonnet", "sonnet[1m]", "haiku"]
    private static let effortOptions = ["", "low", "medium", "high", "max"]
    private static let permissionModes: [PermissionMode] = [.default, .plan, .auto, .acceptEdits, .dontAsk]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                extensionUpdateBanner

                Toggle("SSH Remote", isOn: $isRemoteMode)
                    .toggleStyle(.switch)
                    .padding(.horizontal)

                if isRemoteMode {
                    sshHostCard
                    remoteDirectoryCard
                } else {
                    directoryCard
                }

                sessionOptions
                startButton

                if !recentDirectories.isEmpty || !sessions.isEmpty {
                    Divider().padding(.horizontal)
                    searchField
                }

                if !filteredDirectories.isEmpty {
                    recentDirectoriesSection
                }

                if !filteredSessions.isEmpty {
                    sessionsSection
                }

                Spacer(minLength: 20)
            }
            .padding(40)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadData()
            Task { await updater.checkForUpdate() }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Canopy")
                .font(.largeTitle.bold())
            Text("Claude Code for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Extension Update Banner

    @ViewBuilder
    private var extensionUpdateBanner: some View {
        switch updater.state {
        case .updateAvailable(let cliVersion):
            updateBannerCard(icon: "arrow.down.circle", iconColor: .blue, tint: .blue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extension update available")
                        .font(.subheadline.bold())
                    Text("CLI v\(cliVersion) — update extension to match")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") {
                    Task { await updater.triggerInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .downloading, .installing:
            let text = updater.state == .downloading ? "Downloading extension…" : "Installing extension…"
            updateBannerCard(tint: .secondary) {
                ProgressView().controlSize(.small)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }

        case .done(let version):
            updateBannerCard(icon: "checkmark.circle.fill", iconColor: .green, tint: .green) {
                Text("Extension v\(version) installed. Restart Canopy to apply.")
                    .font(.subheadline)
            }

        case .failed(let message):
            updateBannerCard(icon: "exclamationmark.triangle.fill", iconColor: .orange, tint: .orange) {
                Text("Update failed: \(message)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await updater.checkForUpdate() }
                }
                .controlSize(.small)
            }

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func updateBannerCard<C: View>(
        icon: String? = nil, iconColor: Color = .primary, tint: Color,
        @ViewBuilder content: () -> C
    ) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).foregroundStyle(iconColor)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    // MARK: - Directory Card

    private var directoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working Directory")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(selectedDirectory != nil ? Color.blue : Color.secondary)
                    .font(.title3)

                Text(selectedDirectory?.abbreviatingWithTilde ?? "Select a folder...")
                    .foregroundStyle(selectedDirectory != nil ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Browse...") { chooseFolder() }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isDropTargeted ? Color.blue : (selectedDirectory != nil ? Color.blue.opacity(0.3) : Color.clear),
                        lineWidth: isDropTargeted ? 2 : 1
                    )
            )
        }
    }

    // MARK: - Session Options

    private var sessionOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Model:")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $model) {
                    Text("Auto").tag("")
                    ForEach(Self.modelOptions.dropFirst(), id: \.self) { alias in
                        Text(Self.modelDisplayName(alias)).tag(alias)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            GridRow {
                Text("Effort:")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $effortLevel) {
                    Text("Auto").tag("")
                    ForEach(Self.effortOptions.dropFirst(), id: \.self) { level in
                        Text(level.prefix(1).uppercased() + level.dropFirst()).tag(level)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            GridRow {
                Text("Permission:")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $permissionModeRaw) {
                    ForEach(Self.permissionModes, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                    if CanopySettings.shared.allowDangerouslySkipPermissions {
                        Text(PermissionMode.bypassPermissions.displayName)
                            .tag(PermissionMode.bypassPermissions.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal)
    }

    private static func modelDisplayName(_ alias: String) -> String {
        switch alias {
        case "sonnet[1m]": "Sonnet (1M)"
        default: alias.prefix(1).uppercased() + alias.dropFirst()
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            startSession()
        } label: {
            Label("Start Session", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRemoteMode
            ? (remoteHost.isEmpty || remoteDirectory.isEmpty)
            : selectedDirectory == nil)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Search

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Recent Directories

    private var recentDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Directories")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                let dirs = filteredDirectories
                ForEach(dirs.indices, id: \.self) { index in
                    directoryRow(dirs[index])
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func directoryRow(_ dir: URL) -> some View {
        let isHovered = hoveredDirectoryPath == dir.path
        Button {
            selectedDirectory = dir
            appState.launchSession(directory: dir, model: model.isEmpty ? nil : model, effortLevel: effortLevel.isEmpty ? nil : effortLevel, permissionMode: PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dir.lastPathComponent)
                        .font(.callout.weight(.medium))
                    Text(dir.deletingLastPathComponent().abbreviatingWithTilde)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        RecentDirectories.remove(dir)
                        recentDirectories.removeAll { $0 == dir }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 38)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredDirectoryPath = h ? dir.path : nil }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Sessions")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                let items = filteredSessions
                ForEach(items.indices, id: \.self) { index in
                    sessionRow(items[index])
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @ViewBuilder
    private func sessionRow(_ session: SessionEntry) -> some View {
        let isHovered = hoveredSessionId == session.id
        Button {
            selectedDirectory = session.projectDirectory
            appState.launchSession(directory: session.projectDirectory, resumeSessionId: session.id, sessionTitle: session.title, model: model.isEmpty ? nil : model, effortLevel: effortLevel.isEmpty ? nil : effortLevel, permissionMode: PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(Color.blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.callout)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.projectName)
                            .font(.caption2)
                        Text("·")
                            .font(.caption2)
                        Text(Self.relativeDateFormatter.localizedString(for: session.timestamp, relativeTo: Date()))
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 38)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredSessionId = h ? session.id : nil }
    }

    // MARK: - Filtering

    private var filteredDirectories: [URL] {
        guard !searchText.isEmpty else { return recentDirectories }
        let q = searchText.lowercased()
        return recentDirectories.filter {
            $0.lastPathComponent.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var filteredSessions: [SessionEntry] {
        guard !searchText.isEmpty else { return Array(sessions.prefix(20)) }
        let q = searchText.lowercased()
        return sessions.filter {
            $0.title.lowercased().contains(q) || $0.projectName.lowercased().contains(q)
        }
    }

    // MARK: - SSH Host Card

    private var sshHostCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SSH Host")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(!remoteHost.isEmpty ? Color.blue : Color.secondary)
                    .font(.title3)

                TextField("hostname or user@host", text: $remoteHost)
                    .textFieldStyle(.plain)
                    .onSubmit { startSession() }

                if !savedHosts.isEmpty {
                    Menu {
                        ForEach(savedHosts, id: \.self) { host in
                            Button(host) { remoteHost = host }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Remote Directory Card

    private var remoteDirectoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working Directory")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(!remoteDirectory.isEmpty ? Color.blue : Color.secondary)
                    .font(.title3)

                TextField("Remote path (e.g. ~/projects/myapp)", text: $remoteDirectory)
                    .textFieldStyle(.plain)
                    .onSubmit { startSession() }

                Button("Browse...") {
                    showRemoteBrowser = true
                }
                .disabled(remoteHost.isEmpty)
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .sheet(isPresented: $showRemoteBrowser) {
            RemoteDirectoryBrowser(sshHost: remoteHost) { path in
                remoteDirectory = path
            }
        }
    }

    // MARK: - Actions

    private func startSession() {
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel
        var selectedPermission = PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits
        if selectedPermission == .bypassPermissions && !CanopySettings.shared.allowDangerouslySkipPermissions {
            selectedPermission = .acceptEdits
            permissionModeRaw = PermissionMode.acceptEdits.rawValue
        }

        if isRemoteMode {
            guard !remoteHost.isEmpty, !remoteDirectory.isEmpty else { return }
            SSHHostStore.add(remoteHost)
            savedHosts = SSHHostStore.hosts()
            let dir = URL(fileURLWithPath: remoteDirectory)
            appState.launchSession(directory: dir, model: selectedModel, effortLevel: selectedEffort, permissionMode: selectedPermission, remoteHost: remoteHost)
        } else {
            guard let dir = selectedDirectory else { return }
            appState.launchSession(directory: dir, model: selectedModel, effortLevel: selectedEffort, permissionMode: selectedPermission)
        }
    }

    private func loadData() {
        recentDirectories = RecentDirectories.load()
        savedHosts = SSHHostStore.hosts()
        Task {
            let all = await Task.detached { ClaudeSessionHistory.loadAllSessions() }.value
            sessions = all
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue
                else { return }
                DispatchQueue.main.async { selectedDirectory = url }
            }
        }
        return true
    }
}

// MARK: - URL extension

extension URL {
    var abbreviatingWithTilde: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
