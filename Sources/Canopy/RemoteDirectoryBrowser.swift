import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteDirectoryBrowser")

/// A folder browser for another machine, presented as a sheet: over SSH, or
/// through a paired Mac's server (`browse_dir` / `mkdir`, the verbs the phone uses).
struct RemoteDirectoryBrowser: View {
    enum Source {
        case ssh(host: String)
        case peer(machineId: String, title: String)
    }

    let source: Source
    var onSelect: (String) -> Void

    init(sshHost: String, onSelect: @escaping (String) -> Void) {
        self.init(source: .ssh(host: sshHost), onSelect: onSelect)
    }

    init(source: Source, onSelect: @escaping (String) -> Void) {
        self.source = source
        self.onSelect = onSelect
    }

    @Environment(\.dismiss) private var dismiss

    @State private var currentPath = "~"
    @State private var entries: [DirEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pathInput = "~"
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @FocusState private var nameFieldFocused: Bool
    // Bumped by Cancel so a mkdir that finishes afterwards is discarded.
    @State private var folderCreationID = 0
    @State private var mkdirInFlight = false
    // Off by default, like Finder and `NSOpenPanel`. Remembered across
    // sheets because a person who wants dotfiles wants them every time.
    @AppStorage("canopy.remoteBrowserShowHidden") private var showHidden = false
    @State private var peerConnection = PeerDirectoryConnection()

    struct DirEntry: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                Text("Browse \(sourceName)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Path bar
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                TextField("Path", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !isLoading { navigateTo(pathInput) } }
                Button {
                    navigateTo(pathInput)
                } label: {
                    Image(systemName: "arrow.right")
                }
                .disabled(isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Directory listing
            ZStack {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if currentPath != "/" && currentPath != "~" {
                            Button { navigateUp() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text("..")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(RemoteDirectoryRules.visibleEntries(entries, showHidden: showHidden)) { entry in
                            Button {
                                if entry.isDirectory {
                                    navigateTo(RemoteDirectoryRules.childPath(of: currentPath, name: entry.name))
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                        .frame(width: 16)
                                    Text(entry.name)
                                        .lineLimit(1)
                                    Spacer()
                                    if entry.isDirectory {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar. New Folder… swaps the bar for the name field, so the
            // input appears where the button was.
            HStack {
                if isCreatingFolder {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.blue)
                    TextField("New folder name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFieldFocused)
                        .onSubmit { createFolder() }
                    Button("Cancel") { cancelCreatingFolder() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { createFolder() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(RemoteDirectoryRules.newFolderNameProblem(newFolderName) != nil || isLoading)
                } else {
                    Text(currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Toggle("Show hidden", isOn: $showHidden)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Button("New Folder…") {
                        newFolderName = ""
                        errorMessage = nil
                        isCreatingFolder = true
                        nameFieldFocused = true
                    }
                    // `currentPath` is the remote `pwd`, so it is absolute once
                    // a listing has landed; "~" here means none has, and there
                    // is no directory to make a child of yet.
                    .disabled(isLoading || !currentPath.hasPrefix("/"))
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open") {
                        onSelect(currentPath)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    // `currentPath` is still the previous folder until a listing lands;
                    // a peer refuses a session in "~", which only ssh expands.
                    .disabled(isLoading || (isPeer && !currentPath.hasPrefix("/")))
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            if case .peer(let machineId, _) = source { peerConnection.connect(machineId: machineId) }
            navigateTo("~")
        }
        .onDisappear { peerConnection.close() }
    }

    private var sourceName: String {
        switch source {
        case .ssh(let host): host
        case .peer(_, let title): title
        }
    }

    private var isPeer: Bool {
        if case .peer = source { return true }
        return false
    }

    private var sourceIcon: String { isPeer ? "desktopcomputer" : "network" }

    private func navigateTo(_ path: String) {
        isLoading = true
        errorMessage = nil
        Task {
            let result = await listRemoteDirectory(path: path)
            switch result {
            case .success(let (resolvedPath, items)):
                currentPath = resolvedPath
                pathInput = resolvedPath
                entries = items
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func cancelCreatingFolder() {
        // Only a mkdir's spinner is ours to clear; a listing in flight keeps its own.
        if mkdirInFlight {
            folderCreationID += 1
            mkdirInFlight = false
            isLoading = false
        }
        isCreatingFolder = false
        newFolderName = ""
        errorMessage = nil
    }

    /// `mkdir` without `-p`, deliberately: an existing folder is a real
    /// answer ("File exists"), and `-p` would report success and then
    /// navigate into somebody else's directory.
    private func createFolder() {
        guard !isLoading,
              RemoteDirectoryRules.newFolderNameProblem(newFolderName) == nil,
              currentPath.hasPrefix("/") else { return }
        let name = RemoteDirectoryRules.trimmedName(newFolderName)
        let target = RemoteDirectoryRules.childPath(of: currentPath, name: name)
        folderCreationID += 1
        let creationID = folderCreationID
        mkdirInFlight = true
        isLoading = true
        errorMessage = nil
        Task {
            do {
                var created = target
                switch source {
                case .ssh(let host):
                    // `--`: a name starting with "-" is a folder, not an option.
                    _ = try await runSSH(args: ["-T", "-o", "ConnectTimeout=10", host,
                                                "mkdir", "--", shellEscape(target)])
                case .peer:
                    created = try await peerConnection.mkdir(parent: currentPath, name: name).get()
                }
                logger.notice("created remote folder \(target, privacy: .private) on \(sourceName, privacy: .public)")
                guard creationID == folderCreationID else { return }
                mkdirInFlight = false
                cancelCreatingFolder()
                navigateTo(created)
            } catch {
                logger.error("mkdir failed on \(sourceName, privacy: .public): \(error.localizedDescription, privacy: .private)")
                guard creationID == folderCreationID else { return }
                mkdirInFlight = false
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func navigateUp() {
        guard let slashIdx = currentPath.lastIndex(of: "/") else {
            navigateTo("~")
            return
        }
        let parent = String(currentPath[..<slashIdx])
        navigateTo(parent.isEmpty ? "/" : parent)
    }

    private func listRemoteDirectory(path: String) async -> Result<(String, [DirEntry]), any Error> {
        guard case .ssh(let sshHost) = source else { return await peerConnection.list(path: path) }
        let safePath: String
        if path == "~" {
            safePath = "~"
        } else if path.hasPrefix("~/") {
            safePath = "~/" + shellEscape(String(path.dropFirst(2)))
        } else {
            safePath = shellEscape(path)
        }
        let sshArgs = ["-T", "-o", "ConnectTimeout=10", sshHost,
                        "cd", safePath, "&&", "pwd", "&&", "ls", "-1pA"]

        let output: String
        do {
            output = try await runSSH(args: sshArgs)
        } catch {
            return .failure(error)
        }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let resolvedPath = lines.first else {
            return .failure(NSError(domain: "SSH", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Could not resolve path: \(path)"]))
        }

        let items = lines.dropFirst().compactMap { line -> DirEntry? in
            let isDir = line.hasSuffix("/")
            let name = isDir ? String(line.dropLast()) : line
            guard !name.isEmpty else { return nil }
            return DirEntry(name: name, isDirectory: isDir)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return .success((resolvedPath, items))
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runSSH(args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read stdout and stderr concurrently to avoid pipe deadlock
                // on large directory listings (pipe buffer is ~64KB on macOS).
                var stderrData = Data()
                let stderrGroup = DispatchGroup()
                stderrGroup.enter()
                DispatchQueue.global().async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrGroup.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrGroup.wait()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: NSError(
                        domain: "SSH", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
                    ))
                    return
                }

                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}

/// The pure half of New Folder and the hidden-file toggle, kept off the
/// `View` so it is not main-actor isolated and the probe can reach it.
enum RemoteDirectoryRules {
    static func trimmedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when `name` may be spliced into `mkdir` as one path component.
    static func newFolderNameProblem(_ name: String) -> String? {
        let trimmed = trimmedName(name)
        if trimmed.isEmpty { return "Enter a folder name." }
        if trimmed == "." || trimmed == ".." { return "That name is reserved." }
        if trimmed.contains("/") { return "A folder name cannot contain a slash." }
        // Newlines included: the listing splits `pwd` and `ls` output on them.
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "A folder name cannot contain control characters."
        }
        return nil
    }

    /// The one join both the listing's descend and New Folder use.
    static func childPath(of directory: String, name: String) -> String {
        directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
    }

    /// Drops ".", "..", empty components and trailing slashes from an absolute
    /// path, since a peer echoes back the path it was asked for (ssh answers
    /// with `pwd`). Symlinks are left alone. Anything not absolute is returned
    /// unchanged for the server to refuse.
    static func normalizedAbsolute(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Client side, on the name only, so toggling never re-runs ssh.
    static func visibleEntries(_ entries: [RemoteDirectoryBrowser.DirEntry],
                               showHidden: Bool) -> [RemoteDirectoryBrowser.DirEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }
}

/// The control connection a peer browser lists and creates folders through.
/// TCP with the pairing password, like `refreshRemoteRecents`; opened with the
/// sheet and closed with it.
@MainActor
final class PeerDirectoryConnection {
    private var client: ControlClient?
    private var connectError: String?
    /// That Mac's home folder, learned from the first listing, so "~/x" can be
    /// sent as the absolute path the server requires.
    private var home: String?

    func connect(machineId: String) {
        guard client == nil else { return }
        guard let address = CanopySettings.shared.mirrorPeers[machineId],
              let hostPort = MirrorAccess.parseHostPort(address),
              let token = MirrorAccess.peerToken(machineId: machineId) else {
            connectError = "Paste its connection in Settings › Remote first"
            return
        }
        let client = ControlClient(endpoint: .tcp(host: hostPort.host, port: hostPort.port), token: token)
        self.client = client
        client.start()
    }

    func close() {
        client?.stop()
        client = nil
    }

    func list(path: String) async -> Result<(String, [RemoteDirectoryBrowser.DirEntry]), any Error> {
        var params: [String: Any] = ["showHidden": true]  // the sheet filters hidden names itself
        if path.hasPrefix("~/"), home == nil, case .failure(let error) = await list(path: "~") {
            return .failure(error)
        }
        if path == "~" {
            // No path: the server lists its own home.
        } else if path.hasPrefix("~/"), let home {
            params["path"] = RemoteDirectoryRules.normalizedAbsolute(home + "/" + path.dropFirst(2))
        } else {
            params["path"] = RemoteDirectoryRules.normalizedAbsolute(path)
        }
        return await request("browse_dir", params).flatMap { result in
            guard let resolved = result["path"] as? String, let raw = result["entries"] as? [[String: Any]] else {
                return .failure(Self.error("Unexpected reply from that Mac"))
            }
            if path == "~" { home = resolved }
            let entries = raw.compactMap { entry -> RemoteDirectoryBrowser.DirEntry? in
                guard let name = entry["name"] as? String else { return nil }
                return RemoteDirectoryBrowser.DirEntry(name: name, isDirectory: entry["isDirectory"] as? Bool == true)
            }
            return .success((resolved, entries))
        }
    }

    func mkdir(parent: String, name: String) async -> Result<String, any Error> {
        await request("mkdir", ["parent": parent, "name": name]).flatMap { result in
            guard let path = result["path"] as? String else { return .failure(Self.error("Unexpected reply from that Mac")) }
            return .success(path)
        }
    }

    private func request(_ verb: String, _ params: [String: Any]) async -> Result<[String: Any], any Error> {
        guard let client else { return .failure(Self.error(connectError ?? "Not connected")) }
        guard await client.waitUntilReady() else {
            // A refusal repeats on every reconnect with the same password; stop retrying.
            if client.lastRefusal != nil { client.stop() }
            let message = switch client.lastRefusal {
            case "unauthorized"?: "Password rejected"
            case let refusal?: refusal
            case nil: "Not reachable (is its live mirror on?)"
            }
            return .failure(Self.error(message))
        }
        switch await client.request(verb, params) {
        case .success(let result): return .success(result)
        case .failure(.refused(let message)): return .failure(Self.error(message))
        case .failure(.timedOut): return .failure(Self.error("That Mac did not answer"))
        case .failure(.disconnected): return .failure(Self.error("Not reachable (is its live mirror on?)"))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PeerBrowse", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
