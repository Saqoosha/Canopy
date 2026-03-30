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

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                directoryCard
                permissionPicker
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
        .onAppear(perform: loadData)
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

    // MARK: - Permission Picker

    private var permissionPicker: some View {
        HStack {
            Text("Permission Mode")
                .font(.subheadline)
            Spacer()
            Picker("", selection: $appState.permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            guard let dir = selectedDirectory else { return }
            appState.launchSession(directory: dir)
        } label: {
            Label("Start Session", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selectedDirectory == nil)
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
            appState.launchSession(directory: dir)
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
            appState.launchSession(directory: session.projectDirectory, resumeSessionId: session.id, sessionTitle: session.title)
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

    // MARK: - Actions

    private func loadData() {
        recentDirectories = RecentDirectories.load()
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
