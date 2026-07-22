import SwiftUI

struct LauncherView: View {
    @Bindable var appState: AppState
    /// When true, hide the bottom Recents/Sessions/Web lists — the sidebar
    /// shell already shows them and duplication just adds noise.
    var compactMode: Bool = false

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
    @State private var showCloneSheet = false
    @State private var updater = ExtensionUpdater()

    // Web (Claude Code Web) session teleport
    @State private var showWebSessions = false
    @State private var webSessions: [RemoteSession] = []
    @State private var webSessionsLoading = false
    @State private var webSessionsError: String?
    @State private var teleportingSessionId: String?
    @State private var teleportError: String?
    @State private var hoveredWebSessionId: String?
    @State private var pendingBranchPrompt: BranchPrompt?
    @AppStorage("launcher.webSessionKind") private var webSessionKindRaw = RemoteSessionKind.web.rawValue
    @AppStorage("launcher.webSessionsIncludeArchived") private var webSessionsIncludeArchived = false

    @AppStorage("selectedProviderId") private var selectedProviderId = ""
    @State private var providers: [ModelProvider] = []

    @AppStorage("launcher.model") private var model = ""
    @AppStorage("launcher.effortLevel") private var effortLevel = ""
    @AppStorage("launcher.permissionMode") private var permissionModeRaw = "acceptEdits"
    @AppStorage("launcher.continueSession") private var continueSession = false

    @State private var startInWorktree = false
    @State private var worktreeBranch = ""
    @State private var isCreatingWorktree = false
    /// Computed once per launcher so the placeholder and the empty-field
    /// fallback produce the same branch name (a per-render call would drift
    /// by its seconds-precision timestamp).
    @State private var suggestedWorktreeBranch = GitWorktree.suggestedBranchName()

    // Explicit Opus IDs (not the "opus" alias) for clean version pinning + display.
    // NOTE: the full ID alone does NOT keep you on the 200K tier — for 1M-eligible
    // accounts the CLI upgrades any opus model to "[1m]" at runtime. The actual 200K
    // enforcement is the CLAUDE_CODE_DISABLE_1M_CONTEXT env var set in ShimProcess for
    // non-"[1m]" opus selections. Entries carrying "[1m]" stay on the 1M tier.
    private static let modelOptions = ["", "claude-fable-5", "claude-opus-4-8", "opus[1m]", "claude-opus-4-7", "claude-opus-4-7[1m]", "sonnet", "sonnet[1m]", "haiku"]
    private static let effortOptions = ["", "low", "medium", "high", "xhigh", "max"]
    private static let permissionModes: [PermissionMode] = [.default, .plan, .auto, .acceptEdits, .dontAsk]

    /// Row height for list items (used to calculate fixed list height)
    private static let rowHeight: CGFloat = 34
    private static let listRowCount = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                #if DEBUG
                if ProcessInfo.processInfo.environment["CANOPY_PROBE"] == "1" {
                    ProbeRetentionView()
                }
                #endif
                extensionUpdateBanner

                Toggle("SSH Remote", isOn: $isRemoteMode)
                    .toggleStyle(.switch)
                    .padding(.horizontal)

                sessionOptions

                if isRemoteMode {
                    sshHostCard
                    remoteDirectoryCard
                } else {
                    directoryCard
                }

                startButton

                if !isRemoteMode && !compactMode {
                    searchField
                    listsSection
                    webSessionsSection
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            // Migrate the dropped bare "opus" alias (older builds offered it) to the
            // explicit 200K id so the Picker shows a matching selection after upgrade.
            if model == "opus" { model = "claude-opus-4-8" }
            loadData()
            Task { await updater.checkForUpdate() }
        }
        .onChange(of: selectedProviderId) {
            if !selectedProviderId.isEmpty {
                if permissionModeRaw == PermissionMode.auto.rawValue {
                    permissionModeRaw = PermissionMode.acceptEdits.rawValue
                }
                effortLevel = ""
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var selectedDirectoryIsGitRepo: Bool {
        if let d = selectedDirectory {
            GitWorktree.isGitRepo(d)
        } else {
            false
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
        case .updateAvailable(let latestVersion, let currentVersion):
            updateBannerCard(icon: "arrow.down.circle", iconColor: .blue, tint: .blue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extension update available")
                        .font(.subheadline.bold())
                    HStack(spacing: 6) {
                        if let currentVersion {
                            Text("v\(currentVersion) → v\(latestVersion)")
                        } else {
                            Text("v\(latestVersion)")
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Link("Changelog", destination: ExtensionUpdater.changelogURL)
                            .foregroundStyle(Color.accentColor)
                    }
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
                Spacer()
                Button("Restart Now") {
                    AppDelegate.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

                if !recentDirectories.isEmpty {
                    Menu {
                        Section("Recent") {
                            ForEach(recentDirectories.prefix(15), id: \.path) { dir in
                                Button(dir.lastPathComponent) {
                                    selectedDirectory = dir
                                }
                            }
                        }
                        Divider()
                        Button("Open folder…") { chooseFolder() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .help("Recent folders")
                }

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

            HStack {
                Spacer()
                Button {
                    showCloneSheet = true
                } label: {
                    Label("Clone from GitHub…", systemImage: "arrow.down.circle")
                }
                .help("Clone a GitHub repository into a folder you choose")
            }
        }
        .sheet(isPresented: $showCloneSheet) {
            CloneRepoSheet { cloned in
                selectedDirectory = cloned
                RecentDirectories.add(cloned)
                recentDirectories = RecentDirectories.load()
            }
        }
    }

    // MARK: - Session Options

    private var isAnthropicProvider: Bool { selectedProviderId.isEmpty }

    private var visiblePermissionModes: [PermissionMode] {
        if isAnthropicProvider {
            Self.permissionModes
        } else {
            Self.permissionModes.filter { $0 != .auto }
        }
    }

    private var sessionOptions: some View {
        VStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if !providers.isEmpty {
                    GridRow {
                        Text("Provider:")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: $selectedProviderId) {
                            Text("Anthropic (default)").tag("")
                            ForEach(providers) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

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

                if isAnthropicProvider {
                    GridRow {
                        Text("Effort:")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: $effortLevel) {
                            Text("Auto").tag("")
                            ForEach(Self.effortOptions.dropFirst(), id: \.self) { level in
                                Text(Self.effortDisplayName(level)).tag(level)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                GridRow {
                    Text("Permission:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $permissionModeRaw) {
                        ForEach(visiblePermissionModes, id: \.rawValue) { mode in
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

                if !isRemoteMode && selectedDirectoryIsGitRepo {
                    GridRow {
                        Text("Worktree:")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        HStack {
                            Toggle("Start in new worktree", isOn: $startInWorktree)
                                .toggleStyle(.checkbox)
                            if startInWorktree {
                                TextField("", text: $worktreeBranch, prompt: Text(suggestedWorktreeBranch))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                            }
                        }
                    }
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
        // Explicit full model IDs map to their short marketing name. The latest shows
        // plainly as "Opus"; older pinned versions keep their version number.
        switch alias {
        case "claude-fable-5": return "Fable"
        case "claude-opus-4-8": return "Opus"
        case "claude-opus-4-7": return "Opus 4.7"
        case "claude-opus-4-7[1m]": return "Opus 4.7 (1M)"
        default: break
        }
        // "opus" → "Opus", "opus[1m]" → "Opus (1M)", "sonnet[1m]" → "Sonnet (1M)"
        let (base, suffix) = ModelNameFormatter.splitVariant(alias)
        guard !base.isEmpty else { return alias }
        return base.prefix(1).uppercased() + String(base.dropFirst()) + suffix
    }

    private static func effortDisplayName(_ level: String) -> String {
        switch level {
        case "xhigh": "X-High"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            startSession()
        } label: {
            Label(isCreatingWorktree ? "Creating Worktree…" : "Start Session",
                  systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isCreatingWorktree || (isRemoteMode
            ? (remoteHost.isEmpty || remoteDirectory.isEmpty)
            : selectedDirectory == nil))
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

    // MARK: - Web Sessions Section

    private var webSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Code on the Web")
                    .font(.headline)
                Spacer()
                if showWebSessions && webSessionsLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await toggleWebSessions() }
                } label: {
                    Label(
                        showWebSessions ? "Hide" : "Show",
                        systemImage: showWebSessions ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                }
                .controlSize(.small)
            }

            if showWebSessions {
                HStack(spacing: 10) {
                    Picker("", selection: $webSessionKindRaw) {
                        ForEach(RemoteSessionKind.allCases, id: \.rawValue) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    Toggle("Include archived", isOn: $webSessionsIncludeArchived)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption)
                    Spacer()
                    Button {
                        Task { await fetchWebSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(webSessionsLoading)
                }

                if let webSessionsError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(webSessionsError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") {
                            Task { await fetchWebSessions() }
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    let filtered = filteredWebSessions
                    if filtered.isEmpty && !webSessionsLoading {
                        let kind = RemoteSessionKind(rawValue: webSessionKindRaw) ?? .web
                        Text("No \(kind.displayName.lowercased()) sessions found.\(webSessionsIncludeArchived ? "" : " Toggle 'Include archived' to widen the search.")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, session in
                                    webSessionRow(session)
                                    if index < filtered.count - 1 {
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            }
                        }
                        .frame(height: Self.rowHeight * CGFloat(min(filtered.count, Self.listRowCount)))
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let teleportError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(teleportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .alert(item: $pendingBranchPrompt) { prompt in
            Alert(
                title: Text("Switch git branch?"),
                message: Text("This remote session was on branch '\(prompt.branch)'. Check it out in \(prompt.cwd.lastPathComponent) to keep file context aligned?"),
                primaryButton: .default(Text("Switch")) {
                    prompt.onDecision(true)
                },
                secondaryButton: .cancel(Text("Skip")) {
                    prompt.onDecision(false)
                }
            )
        }
        .onDisappear {
            // Safety net: if the window closes while the alert is up, fire
            // the decision so the awaiting Task can finish and shutdown the
            // bridge subprocess. ResolveOnce makes this a no-op if a button
            // already responded.
            if let prompt = pendingBranchPrompt {
                prompt.onDecision(false)
                pendingBranchPrompt = nil
            }
        }
    }

    private func webSessionRow(_ session: RemoteSession) -> some View {
        let isHovered = hoveredWebSessionId == session.id
        let isTeleporting = teleportingSessionId == session.id
        return Button {
            Task { await teleport(session) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.status == "running" ? "circle.fill" : "globe")
                    .foregroundStyle(session.status == "running" ? .green : .blue)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let owner = session.repoOwner, let name = session.repoName {
                            Text("\(owner)/\(name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let branch = session.displayBranch {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(branch)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: session.lastModified))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isTeleporting {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(teleportingSessionId != nil)
        .onHover { h in hoveredWebSessionId = h ? session.id : nil }
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
            appState.launchSession(directory: session.projectDirectory, resumeSessionId: session.id, sessionTitle: session.title, model: model.isEmpty ? nil : model, effortLevel: effortLevel.isEmpty ? nil : effortLevel, permissionMode: resolvedPermission, customApi: buildCustomApiConfig())
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
        guard !searchText.isEmpty else { return Array(sessions.prefix(50)) }
        let q = searchText.lowercased()
        return Array(sessions.filter {
            $0.title.lowercased().contains(q) || $0.projectName.lowercased().contains(q)
        }.prefix(50))
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

    private func buildCustomApiConfig() -> ModelProvider? {
        guard !selectedProviderId.isEmpty else { return nil }
        return providers.first { $0.id == selectedProviderId }
    }

    private func latestSession(for directory: URL) -> SessionEntry? {
        // Query disk directly so remote-only paths (SSH workspace folders that
        // don't exist locally) still surface a session. The in-memory `sessions`
        // list is populated by loadAllSessions, which excludes entries whose
        // cwd is missing locally — fine for UI listing, wrong for continue.
        ClaudeSessionHistory.loadSessions(for: directory)
            .max { $0.timestamp < $1.timestamp }
    }

    /// Launch from a recent directory row. If "Continue session" is on, resume the most recent session for that directory.
    private func launchFromDirectory(_ dir: URL) {
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel

        var resumeId: String?
        var resumeTitle: String?
        if continueSession, let latest = latestSession(for: dir) {
            resumeId = latest.id
            resumeTitle = latest.title
        }
        appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: selectedModel, effortLevel: selectedEffort, permissionMode: resolvedPermission, customApi: buildCustomApiConfig())
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
            launchLocal(URL(fileURLWithPath: remoteDirectory), remoteHost: remoteHost,
                        model: selectedModel, effort: selectedEffort, permission: selectedPermission)
            return
        }

        guard let local = selectedDirectory else { return }
        guard startInWorktree, selectedDirectoryIsGitRepo else {
            launchLocal(local, remoteHost: nil,
                        model: selectedModel, effort: selectedEffort, permission: selectedPermission)
            return
        }

        // Worktree checkout can take seconds on big repos — keep it off the
        // main thread and disable the Start button while it runs.
        var branch = GitWorktree.sanitizeBranchName(worktreeBranch)
        if branch.isEmpty {
            branch = suggestedWorktreeBranch
        }
        // Reflect what will actually be used, so a sanitized or auto-generated
        // name is never a silent surprise.
        worktreeBranch = branch
        isCreatingWorktree = true
        let repo = local
        let branchName = branch
        Task {
            defer { isCreatingWorktree = false }
            do {
                let worktree = try await Task.detached(priority: .userInitiated) {
                    try GitWorktree.createWorktree(repo: repo, branch: branchName)
                }.value
                launchLocal(worktree, remoteHost: nil,
                            model: selectedModel, effort: selectedEffort, permission: selectedPermission)
            } catch {
                // NSAlert instead of a SwiftUI .alert: the user can navigate
                // away mid-creation, destroying this view's @State — a
                // view-bound alert would never appear (silent failure).
                let alert = NSAlert()
                alert.messageText = "Worktree Creation Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func launchLocal(_ dir: URL, remoteHost: String?, model: String?, effort: String?, permission: PermissionMode) {
        var resumeId: String?
        var resumeTitle: String?
        if continueSession, let latest = latestSession(for: dir) {
            resumeId = latest.id
            resumeTitle = latest.title
        }
        appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: model, effortLevel: effort, permissionMode: permission, remoteHost: remoteHost, customApi: buildCustomApiConfig())
    }

    private func loadData() {
        ModelProviderStore.migrateIfNeeded()
        providers = ModelProviderStore.load()
        recentDirectories = RecentDirectories.load()
        savedHosts = SSHHostStore.hosts()
        Task {
            let all = await Task.detached { ClaudeSessionHistory.loadAllSessions() }.value
            sessions = all
        }
    }

    // MARK: - Web Sessions / Teleport

    private func toggleWebSessions() async {
        showWebSessions.toggle()
        if showWebSessions && webSessions.isEmpty && !webSessionsLoading {
            await fetchWebSessions()
        }
    }

    private func fetchWebSessions() async {
        webSessionsError = nil
        webSessionsLoading = true
        defer { webSessionsLoading = false }

        do {
            let sessions = try await RemoteSessionsAPI.listAll()
            webSessions = sessions.sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
                return $0.lastModified > $1.lastModified
            }
            // Empty result is a valid response — surface it as the empty-state
            // message in the list, not as a "you might not be logged in" error.
            // Real auth/HTTP errors throw and are caught below.
        } catch {
            webSessionsError = error.localizedDescription
        }
    }

    private var filteredWebSessions: [RemoteSession] {
        let kind = RemoteSessionKind(rawValue: webSessionKindRaw) ?? .web
        return webSessions.filter { session in
            guard session.kind == kind else { return false }
            if !webSessionsIncludeArchived && session.status == "archived" { return false }
            return true
        }
    }

    private func teleport(_ session: RemoteSession) async {
        teleportError = nil
        teleportingSessionId = session.id
        defer { teleportingSessionId = nil }

        guard let cwd = resolveTeleportCwd(for: session) else {
            teleportError = "Could not find a local clone of \(session.repoOwner ?? "?")/\(session.repoName ?? "?"). Pick a working directory first."
            return
        }

        // Validate cwd exists before spawning a shim that would otherwise time
        // out 30s later with a generic error.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            teleportError = "Working directory not found: \(cwd.path)"
            return
        }

        let bridge = RemoteSessionsBridge(cwd: cwd)
        do {
            try await bridge.start()
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            bridge.shutdown()
            return
        }
        // Tear the shim down on every exit path past start(), including SwiftUI
        // task cancellation (window close mid-flight) — otherwise the Node
        // process is orphaned.
        defer { bridge.shutdown() }

        let result: TeleportResult
        do {
            result = try await bridge.teleportSession(id: session.id)
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            return
        }

        // If extension returned a branch, ask the user before checking it out.
        // If they said Switch but the checkout failed, abort instead of resuming
        // on the wrong branch — running teleported history against the wrong
        // working copy is worse than not resuming at all.
        if let branch = result.branch, !branch.isEmpty {
            let switchToBranch = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Wrap the decision callback so the continuation can only be
                // resumed once — even if both Alert and onDisappear fire.
                let resolved = ResolveOnce(cont)
                pendingBranchPrompt = BranchPrompt(branch: branch, cwd: cwd) { decision in
                    resolved.fire(decision)
                }
            }
            pendingBranchPrompt = nil

            if switchToBranch {
                var checkoutFailed = false
                do {
                    checkoutFailed = !(try await bridge.checkoutBranch(branch))
                } catch {
                    checkoutFailed = true
                }
                if checkoutFailed {
                    try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: true)
                    teleportError = "Couldn't switch to branch '\(branch)' in \(cwd.lastPathComponent). The session was saved locally but not resumed — switch the branch manually and use Continue session, or pick a different working directory."
                    return
                }
            } else {
                try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: false)
            }
        }

        guard let localId = result.localSessionId else {
            teleportError = "Teleport completed but no local session id was returned."
            return
        }

        appState.launchSession(
            directory: cwd,
            resumeSessionId: localId,
            sessionTitle: result.summary ?? session.summary,
            model: model.isEmpty ? nil : model,
            effortLevel: effortLevel.isEmpty ? nil : effortLevel,
            permissionMode: resolvedPermission,
            customApi: buildCustomApiConfig()
        )
    }

    private func resolveTeleportCwd(for session: RemoteSession) -> URL? {
        if let selected = selectedDirectory { return selected }

        // Find recents whose lastPathComponent matches the repo name. If
        // exactly one matches, auto-confirm. If multiple, prompt the
        // user — picking the wrong clone of "myapp" and then running
        // checkoutBranch on it could damage unrelated work.
        if let repoName = session.repoName?.lowercased() {
            let matches = recentDirectories.filter { $0.lastPathComponent.lowercased() == repoName }
            if matches.count == 1, let only = matches.first {
                return only
            }
        }

        // Either zero matches or ambiguous — prompt the user.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let owner = session.repoOwner, let name = session.repoName {
            panel.message = "Pick the local clone of \(owner)/\(name) to teleport into"
        } else {
            panel.message = "Choose a local working directory for this remote session"
        }
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select a project directory"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
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
        return true
    }
}

// MARK: - Supporting Types

struct BranchPrompt: Identifiable {
    let id = UUID()
    let branch: String
    let cwd: URL
    let onDecision: (Bool) -> Void
}

/// Wraps a CheckedContinuation so it can only be resumed once. Used to bridge
/// SwiftUI alerts (which can fire buttons OR be dismissed via system gestures)
/// to async code without leaking continuations.
final class ResolveOnce<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) {
        self.cont = cont
    }
    func fire(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
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
