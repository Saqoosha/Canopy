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
                    .onSubmit { navigateTo(pathInput) }
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

                        ForEach(entries) { entry in
                            Button {
                                if entry.isDirectory {
                                    let newPath = currentPath.hasSuffix("/")
                                        ? "\(currentPath)\(entry.name)"
                                        : "\(currentPath)/\(entry.name)"
                                    navigateTo(newPath)
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

            // Bottom bar
            HStack {
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    onSelect(currentPath)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
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
