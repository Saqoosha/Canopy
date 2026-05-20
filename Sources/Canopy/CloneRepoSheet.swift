import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CloneRepoSheet")

/// Sheet for cloning a GitHub repo into a user-chosen parent directory. On
/// success calls `onCloned` with the newly created directory URL so the
/// launcher can drop straight into a session there.
struct CloneRepoSheet: View {
    var onCloned: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var repoInput: String = ""
    @State private var branch: String = ""
    @AppStorage("launcher.clone.parentDir") private var parentDirPath: String = ""
    @State private var isCloning = false
    @State private var errorMessage: String?

    private var parentDir: URL? {
        guard !parentDirPath.isEmpty else { return nil }
        return URL(fileURLWithPath: parentDirPath)
    }

    private var derivedRepoName: String? {
        Self.deriveRepoName(from: repoInput)
    }

    private var targetURL: URL? {
        guard let parent = parentDir, let name = derivedRepoName else { return nil }
        return parent.appendingPathComponent(name)
    }

    private var targetExists: Bool {
        guard let target = targetURL else { return false }
        return FileManager.default.fileExists(atPath: target.path)
    }

    private var canClone: Bool {
        !isCloning
            && derivedRepoName != nil
            && parentDir != nil
            && !targetExists
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Clone GitHub Repository")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "owner/repo, https://github.com/owner/repo, or git@github.com:owner/repo.git",
                        text: $repoInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(isCloning)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Parent Directory")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(parentDir != nil ? Color.blue : Color.secondary)
                        Text(parentDir?.abbreviatingWithTilde ?? "Choose parent folder…")
                            .foregroundStyle(parentDir != nil ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseParent() }
                            .disabled(isCloning)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Branch (optional)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Defaults to repository's default branch", text: $branch)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .disabled(isCloning)
                }

                if let target = targetURL {
                    HStack(spacing: 6) {
                        Image(systemName: targetExists ? "exclamationmark.triangle.fill" : "arrow.right")
                            .foregroundStyle(targetExists ? Color.orange : Color.secondary)
                            .font(.caption)
                        Text(
                            targetExists
                                ? "Already exists: \(target.abbreviatingWithTilde)"
                                : "Will clone into: \(target.abbreviatingWithTilde)"
                        )
                        .font(.caption)
                        .foregroundStyle(targetExists ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Spacer()
                    }
                }

                if isCloning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cloning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCloning)
                Button("Clone") { Task { await runClone() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canClone)
            }
            .padding()
        }
        .frame(width: 540, height: 400)
        .onAppear {
            if parentDirPath.isEmpty {
                parentDirPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to clone the repository"
        panel.prompt = "Use This Folder"
        if let current = parentDir {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            parentDirPath = url.path
        }
    }

    private func runClone() async {
        errorMessage = nil
        guard let target = targetURL else { return }
        let repo = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        isCloning = true
        defer { isCloning = false }

        do {
            try await GitCloner.clone(
                repo: repo,
                target: target,
                branch: trimmedBranch.isEmpty ? nil : trimmedBranch
            )
            onCloned(target)
            dismiss()
        } catch let CloneError.failed(message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parses a repo input into the local folder name we'd clone into.
    /// Returns nil for inputs that don't end in a usable folder name.
    static func deriveRepoName(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        // ssh form: git@host:owner/repo → drop everything up to ':'
        if s.hasPrefix("git@"), let colonIdx = s.firstIndex(of: ":") {
            s = String(s[s.index(after: colonIdx)...])
        }
        // https://host/path → drop scheme + host
        if let schemeRange = s.range(of: "://") {
            let afterScheme = s[schemeRange.upperBound...]
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                s = String(afterScheme[afterScheme.index(after: slashIdx)...])
            } else {
                return nil
            }
        }

        if let lastSlash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: lastSlash)...])
        }

        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>| ")
        if s.rangeOfCharacter(from: invalid) != nil { return nil }
        return s.isEmpty ? nil : s
    }
}

// MARK: - GitCloner

enum CloneError: Error {
    case failed(String)
}

enum GitCloner {
    static func clone(repo: String, target: URL, branch: String?) async throws {
        // Make sure the parent dir actually exists before we hand off — git's
        // error for a missing parent is a generic "could not create work tree"
        // that doesn't make the cause obvious.
        let parent = target.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw CloneError.failed("Parent directory does not exist: \(parent.path)")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw CloneError.failed("Target directory already exists: \(target.path)")
        }

        if let ghPath = findGh(), await isGhAuthenticated(ghPath: ghPath) {
            logger.info("Using gh for clone: \(ghPath, privacy: .public)")
            try await runGhClone(ghPath: ghPath, repo: repo, target: target, branch: branch)
        } else {
            logger.info("Using git for clone")
            try await runGitClone(repo: repo, target: target, branch: branch)
        }
    }

    private static func findGh() -> String? {
        let paths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(NSHomeDirectory())/.local/bin/gh",
        ]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private static func findGit() -> String {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "/usr/bin/git"
    }

    private static func isGhAuthenticated(ghPath: String) async -> Bool {
        let result = await runProcess(executable: ghPath, args: ["auth", "status"])
        return result.status == 0
    }

    private static func runGhClone(ghPath: String, repo: String, target: URL, branch: String?) async throws {
        var args = ["repo", "clone", repo, target.path]
        if let branch, !branch.isEmpty {
            // Everything after `--` is forwarded to git clone.
            args.append(contentsOf: ["--", "--branch", branch])
        }
        let result = await runProcess(executable: ghPath, args: args)
        if result.status != 0 {
            throw CloneError.failed(
                result.errorOutput.isEmpty
                    ? "gh repo clone exited with status \(result.status)"
                    : result.errorOutput
            )
        }
    }

    private static func runGitClone(repo: String, target: URL, branch: String?) async throws {
        let gitPath = findGit()
        let normalized = normalizeForGit(repo)
        var args = ["clone"]
        if let branch, !branch.isEmpty {
            args.append(contentsOf: ["--branch", branch])
        }
        args.append(contentsOf: [normalized, target.path])
        let result = await runProcess(executable: gitPath, args: args)
        if result.status != 0 {
            throw CloneError.failed(
                result.errorOutput.isEmpty
                    ? "git clone exited with status \(result.status)"
                    : result.errorOutput
            )
        }
    }

    private static func normalizeForGit(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("git@") {
            return trimmed
        }
        let stripped = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        return "https://github.com/\(stripped).git"
    }

    struct ProcessResult {
        let status: Int32
        let errorOutput: String
    }

    private static func runProcess(executable: String, args: [String]) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

                let stderrPipe = Pipe()
                let stdoutPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = stdoutPipe

                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ProcessResult(status: -1, errorOutput: error.localizedDescription))
                    return
                }

                // Drain stderr concurrently so the pipe never fills up (the
                // buffer is ~64 KB on macOS and a chatty clone can fill it).
                var stderrData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                let summary: String
                if process.terminationStatus != 0 {
                    let lines = stderrText
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    summary = lines.suffix(6).joined(separator: "\n")
                } else {
                    summary = ""
                }
                cont.resume(returning: ProcessResult(status: process.terminationStatus, errorOutput: summary))
            }
        }
    }
}
