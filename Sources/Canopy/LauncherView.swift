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
    @AppStorage("launcher.continueSession") private var continueSession = false

    private static let modelOptions = ["", "opus", "sonnet", "sonnet[1m]", "haiku"]
    private static let effortOptions = ["", "low", "medium", "high", "max"]
    private static let permissionModes: [PermissionMode] = [.default, .plan, .auto, .acceptEdits, .dontAsk]

    /// Row height for list items (used to calculate fixed list height)
    private static let rowHeight: CGFloat = 34
    private static let listRowCount = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                extensionUpdateBanner

                Toggle("SSH Remote", isOn: $isRemoteMode)
                    .toggleStyle(.switch)
                    .padding(.horizontal)

                if isRemoteMode {
                    sshHostCard
                    remoteDirectoryCard
                } else {
                    sessionOptions
                    directoryCard
                    startButton
                    searchField
                    listsSection
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Canopy")
                .font(.title.bold())
            Text("Start a new session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
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
        VStack(spacing: 12) {
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

            HStack(spacing: 16) {
                Toggle("Continue session", isOn: $continueSession)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity)
        }
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

    // MARK: - Lists (side by side)

    private var listsSection: some View {
        HStack(alignment: .top, spacing: 20) {
            // Recent directories (left)
            VStack(alignment: .leading, spacing: 8) {
                Text("Recents")
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 0) {
                        let dirs = filteredDirectories
                        ForEach(Array(dirs.enumerated()), id: \.element.path) { index, dir in
                            directoryRow(dir)
                            if index < dirs.count - 1 {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(Self.listRowCount))
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)

            // Sessions (right)
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions")
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 0) {
                        let items = filteredSessions
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, session in
                            sessionRow(session)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(Self.listRowCount))
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Recent Row

    private func directoryRow(_ dir: URL) -> some View {
        let isSelected = selectedDirectory == dir
        let isHovered = hoveredDirectoryPath == dir.path
        return Button {
            selectedDirectory = dir
            launchFromDirectory(dir)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                Text(dir.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        RecentDirectories.remove(dir)
                        recentDirectories.removeAll { $0 == dir }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(dir.deletingLastPathComponent().abbreviatingWithTilde)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : isHovered ? Color.primary.opacity(0.04) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredDirectoryPath = h ? dir.path : nil }
    }

    // MARK: - Session Row

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func sessionRow(_ session: SessionEntry) -> some View {
        let isHovered = hoveredSessionId == session.id
        return Button {
            selectedDirectory = session.projectDirectory
            appState.launchSession(directory: session.projectDirectory, resumeSessionId: session.id, sessionTitle: session.title, model: model.isEmpty ? nil : model, effortLevel: effortLevel.isEmpty ? nil : effortLevel, permissionMode: PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: session.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
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

    private var resolvedPermission: PermissionMode {
        var perm = PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits
        if perm == .bypassPermissions && !CanopySettings.shared.allowDangerouslySkipPermissions {
            perm = .acceptEdits
        }
        return perm
    }

    /// Launch from a recent directory row. If "Continue session" is on, resume the most recent session for that directory.
    private func launchFromDirectory(_ dir: URL) {
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel

        var resumeId: String?
        var resumeTitle: String?
        if continueSession {
            if let latest = sessions.first(where: { $0.projectDirectory == dir }) {
                resumeId = latest.id
                resumeTitle = latest.title
            }
        }
        appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: selectedModel, effortLevel: selectedEffort, permissionMode: resolvedPermission)
    }

    private func startSession() {
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel
        let selectedPermission = resolvedPermission
        if selectedPermission != PermissionMode(rawValue: permissionModeRaw) {
            permissionModeRaw = selectedPermission.rawValue
        }

        if isRemoteMode {
            guard !remoteHost.isEmpty, !remoteDirectory.isEmpty else { return }
            SSHHostStore.add(remoteHost)
            savedHosts = SSHHostStore.hosts()
            let dir = URL(fileURLWithPath: remoteDirectory)
            appState.launchSession(directory: dir, model: selectedModel, effortLevel: selectedEffort, permissionMode: selectedPermission, remoteHost: remoteHost)
        } else {
            guard let dir = selectedDirectory else { return }
            var resumeId: String?
            var resumeTitle: String?
            if continueSession {
                if let latest = sessions.first(where: { $0.projectDirectory == dir }) {
                    resumeId = latest.id
                    resumeTitle = latest.title
                }
            }
            appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: selectedModel, effortLevel: selectedEffort, permissionMode: selectedPermission)
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
