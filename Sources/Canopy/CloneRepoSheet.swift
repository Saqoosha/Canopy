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
    @State private var didFinishCloning = false
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

                if let target = targetURL, !didFinishCloning {
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
            // Suppress the "Will clone into / Already exists" hint before
            // dismiss runs — body re-renders between dismiss() and the
            // actual sheet teardown, and the hint would briefly flash to
            // "Already exists" because we just created the directory.
            didFinishCloning = true
            onCloned(target)
            dismiss()
        } catch let CloneError.failed(message) {
            logger.error("Clone failed: \(message, privacy: .public)")
            errorMessage = message
        } catch {
            logger.error("Clone failed with unexpected error: \(String(describing: error), privacy: .public)")
            errorMessage = "Clone failed: \(error.localizedDescription)"
        }
    }

    /// Parses a repo input into the local folder name we'd clone into.
    /// Accepts `owner/repo`, `https://host/owner/repo[.git]`, and
    /// `git@host:owner/repo[.git]`. Returns nil for inputs that lack an
    /// `owner/name` structure or contain shell/path metacharacters.
    static func deriveRepoName(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        if s.hasPrefix("git@"), let colonIdx = s.firstIndex(of: ":") {
            s = String(s[s.index(after: colonIdx)...])
        }
        if let schemeRange = s.range(of: "://") {
            let afterScheme = s[schemeRange.upperBound...]
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                s = String(afterScheme[afterScheme.index(after: slashIdx)...])
            } else {
                return nil
            }
        }

        // A bare `owner` (no slash) is ambiguous on the `git` fallback path —
        // we'd synthesize `https://github.com/owner.git` which never resolves.
        // Reject upfront so the Clone button stays disabled with the
        // placeholder hint visible.
        guard s.contains("/") else { return nil }

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
        // Pre-flight the parent dir: git's own error for a missing parent is
        // a generic "could not create work tree" that hides the real cause.
        let parent = target.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw CloneError.failed("Parent directory does not exist: \(parent.path)")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw CloneError.failed("Target directory already exists: \(target.path)")
        }

        // Prefer `gh` when authenticated so private repos work without the
        // user having to configure SSH keys or a credential helper. Fall
        // back to plain `git` otherwise.
        if let ghPath = findGh() {
            if await isGhAuthenticated(ghPath: ghPath) {
                logger.info("Using gh for clone: \(ghPath, privacy: .public)")
                try await runGhClone(ghPath: ghPath, repo: repo, target: target, branch: branch)
                return
            } else {
                logger.warning("gh at \(ghPath, privacy: .public) is not authenticated; falling back to git (private repos will fail)")
            }
        } else {
            logger.info("gh not found; using git")
        }
        try await runGitClone(repo: repo, target: target, branch: branch)
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
            // `--` separates gh's own args from flags forwarded to git clone.
            args.append(contentsOf: ["--", "--branch", branch])
        }
        let result = await runProcess(executable: ghPath, args: args)
        try throwIfFailed(tool: "gh repo clone", path: ghPath, result: result)
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
        try throwIfFailed(tool: "git clone", path: gitPath, result: result)
    }

    private static func throwIfFailed(tool: String, path: String, result: ProcessResult) throws {
        if let spawnError = result.spawnError {
            throw CloneError.failed("Couldn't start \(tool) at \(path): \(spawnError)")
        }
        if result.status == 0 { return }
        let prefix = result.terminatedBySignal
            ? "\(tool) was terminated by a signal (status \(result.status))"
            : "\(tool) exited with status \(result.status)"
        throw CloneError.failed(
            result.errorOutput.isEmpty ? prefix : "\(prefix):\n\(result.errorOutput)"
        )
    }

    private static func normalizeForGit(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("git@") {
            return trimmed
        }
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        let stripped = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        return "https://github.com/\(stripped).git"
    }

    struct ProcessResult {
        let status: Int32
        let errorOutput: String
        let spawnError: String?
        let terminatedBySignal: Bool
    }

    private static func runProcess(executable: String, args: [String]) async -> ProcessResult {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
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

                    handle.attach(process)

                    do {
                        try process.run()
                    } catch {
                        let message = error.localizedDescription
                        logger.error("Failed to spawn \(executable, privacy: .public): \(message, privacy: .public)")
                        cont.resume(returning: ProcessResult(
                            status: -1,
                            errorOutput: message,
                            spawnError: message,
                            terminatedBySignal: false
                        ))
                        return
                    }

                    // Drain stderr concurrently — a chatty `git clone` can fill
                    // the pipe buffer and deadlock the writer before we get to
                    // read it after stdout completes.
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
                    let signaled = process.terminationReason == .uncaughtSignal
                    let status = process.terminationStatus

                    // Log stderr regardless of exit code — git and gh emit
                    // diagnostic warnings (auth scope, LFS misses, partial
                    // fetches) on the success path that we'd otherwise lose.
                    if !stderrText.isEmpty {
                        let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if status == 0 {
                            logger.info("\(executable, privacy: .public) stderr: \(trimmed, privacy: .public)")
                        } else {
                            logger.error("\(executable, privacy: .public) failed (status \(status), signal=\(signaled)): \(trimmed, privacy: .public)")
                        }
                    }

                    let summary: String
                    if status != 0 {
                        let lines = stderrText
                            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        summary = lines.suffix(6).joined(separator: "\n")
                    } else {
                        summary = ""
                    }
                    cont.resume(returning: ProcessResult(
                        status: status,
                        errorOutput: summary,
                        spawnError: nil,
                        terminatedBySignal: signaled
                    ))
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }
}

/// Holds a weakly-shared reference to a running `Process` so the cancellation
/// handler can `terminate()` it from outside the dispatch block that owns it.
/// Without this, dismissing the sheet mid-clone orphans the subprocess.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func attach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
        }
    }
}
