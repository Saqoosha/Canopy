import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteDirectoryBrowser")

/// SSH-backed remote directory browser, presented as a sheet.
struct RemoteDirectoryBrowser: View {
    let sshHost: String
    var onSelect: (String) -> Void

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

    struct DirEntry: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text("Browse \(sshHost)")
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
                    // `currentPath` is still the previous folder until a listing lands.
                    .disabled(isLoading)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear { navigateTo("~") }
    }

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
                // `--`: a name starting with "-" is a folder, not an option.
                _ = try await runSSH(args: ["-T", "-o", "ConnectTimeout=10", sshHost,
                                            "mkdir", "--", shellEscape(target)])
                logger.notice("created remote folder \(target, privacy: .private) on \(sshHost, privacy: .public)")
                guard creationID == folderCreationID else { return }
                mkdirInFlight = false
                cancelCreatingFolder()
                navigateTo(target)
            } catch {
                logger.error("mkdir failed on \(sshHost, privacy: .public): \(error.localizedDescription, privacy: .private)")
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

    /// Client side, on the name only, so toggling never re-runs ssh.
    static func visibleEntries(_ entries: [RemoteDirectoryBrowser.DirEntry],
                               showHidden: Bool) -> [RemoteDirectoryBrowser.DirEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }
}
