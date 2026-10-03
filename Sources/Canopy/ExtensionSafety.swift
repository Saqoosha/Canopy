import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ExtensionUpdater")

/// Starts a freshly downloaded Claude Code extension in a throwaway shim before Canopy adopts it.
/// It checks activation only: no CLI is spawned and no message is exchanged. Extension updates
/// that threw during `activate` (#193, #276) would have been stopped here.
enum ExtensionCanary {
    enum Outcome: Equatable {
        case passed
        case failed(String)
        case undecided
    }

    /// The verdict so far from the shim's NDJSON stdout: it writes `ready` only after `activate`
    /// returned, and an `error` frame then exits 1 when activation threw.
    static func outcome(stdout: String, exitStatus: Int32?) -> Outcome {
        for line in stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch frame["type"] as? String {
            case "ready": return .passed
            case "error": return .failed(frame["message"] as? String ?? "the extension reported an error")
            default: continue
            }
        }
        if let exitStatus { return .failed("the extension host exited with status \(exitStatus) before it was ready") }
        return .undecided
    }

    /// Runs the shim against `extensionDir` with a scratch HOME, so it touches none of the user's
    /// storage, and returns once it is ready, fails, or `timeout` passes. Blocks; call off the main thread.
    static func run(extensionDir: URL, nodePath: String, shimPath: String, timeout: TimeInterval = 20) -> Outcome {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("cc-ext-canary-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let home = scratch.appendingPathComponent("home")
        let cwd = scratch.appendingPathComponent("cwd")
        let settings = scratch.appendingPathComponent("settings.json")
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: settings)
        } catch {
            return .failed("could not prepare the check: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedNodePath(nodePath))
        process.arguments = [shimPath, "--extension-path", extensionDir.path, "--cwd", cwd.path,
                             "--settings-path", settings.path]
        // As a real shim gets it, and pointed away from the user's own Claude config.
        var environment = ShimProcess.scrubbingCanopyAssignedKeys(ProcessInfo.processInfo.environment)
        environment["HOME"] = home.path
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        let buffer = OutputBuffer()
        let errBuffer = OutputBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuffer.append(data) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
        do {
            try process.run()
        } catch {
            return .failed("could not start the extension host: \(error.localizedDescription)")
        }
        // Declared after the scratch folder's defer, so it runs first: the shim is gone before its HOME is.
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let killAt = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.05) }
                // SIGTERM is handled in JS, so a shim stuck in synchronous code never sees it.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                // Read what the handler has not delivered yet, so the error frame written just
                // before `exit(1)` decides the verdict rather than the bare status.
                stdout.fileHandleForReading.readabilityHandler = nil
                buffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderr.fileHandleForReading.readabilityHandler = nil
                errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                return logged(outcome(stdout: buffer.text, exitStatus: process.terminationStatus),
                              stdout: buffer.text, stderr: errBuffer.text)
            }
            let verdict = outcome(stdout: buffer.text, exitStatus: nil)
            if verdict != .undecided { return logged(verdict, stdout: buffer.text, stderr: errBuffer.text) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return .failed("the extension host did not become ready within \(Int(timeout)) s")
    }

    /// The error frame's `stack` names the extension's file:line, which is what identifies the
    /// API the shim lacks; the user-facing message does not carry it.
    /// The node a version manager's shim (mise, asdf, nvm, Volta) stands for. The shim picks it
    /// from HOME, which the check replaces, so ask under the user's own environment first.
    /// Measured: mise's shim under a scratch HOME exits 1 with "node is not a valid shim".
    static func resolvedNodePath(_ nodePath: String) -> String {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: nodePath)
        probe.arguments = ["-e", "process.stdout.write(process.execPath)"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        probe.standardInput = FileHandle.nullDevice
        do { try probe.run() } catch { return nodePath }
        let deadline = Date().addingTimeInterval(10)
        while probe.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if probe.isRunning { probe.terminate(); return nodePath }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard probe.terminationStatus == 0, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nodePath }
        return path
    }

    private static func logged(_ verdict: Outcome, stdout: String, stderr: String) -> Outcome {
        guard case .failed = verdict else { return verdict }
        // "exited with status 1" alone does not say why; the host's last words usually do.
        let tail = stderr.suffix(800)
        if !tail.isEmpty { logger.error("Extension start check stderr: \(String(tail), privacy: .public)") }
        for line in stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["type"] as? String == "error", let stack = frame["stack"] as? String else { continue }
            logger.error("Extension start check stack: \(stack, privacy: .public)")
            break
        }
        return verdict
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Removes old extension versions from Canopy's folder, but never the newest one there and never
/// one a running process names on its command line, which covers shims (each later spawns its CLI
/// from `resources/native-binary` inside its own version's folder). A webview that loaded its
/// assets from an older folder is not covered: that path is on no command line.
enum ExtensionCleanup {
    /// Entries of `dir` to delete. The newest version by version order stays (it is what new
    /// sessions use, and an install just made it), and so does any folder whose full path appears
    /// in `psOutput`, whatever arguments surround it. A nil or empty `psOutput` means the process
    /// list could not be read, which is not the same as nothing running: nothing is removed.
    static func removable(installed: [String], in dir: String, psOutput: String?) -> [String] {
        guard let psOutput, !psOutput.isEmpty else { return [] }
        let folders = installed.filter { $0.hasPrefix("anthropic.claude-code-") }
        let newest = folders.max { $0.compare($1, options: .numeric) == .orderedAscending }
        return folders.filter { $0 != newest && !psOutput.contains("\(dir)/\($0)") }
    }

    /// Deletes what `removable` names in Canopy's extensions folder. Blocks on `ps`.
    static func removeUnused() {
        let dir = CCExtension.canopyExtensionsDir
        let installed: [String]
        do {
            installed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            logger.warning("Extension cleanup skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let commands = runningCommands() else {
            logger.error("Extension cleanup skipped: the process list could not be read, so versions in use are unknown")
            return
        }
        for name in removable(installed: installed, in: dir.path, psOutput: commands) {
            do {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                logger.notice("Cleaned up old extension: \(name, privacy: .public)")
            } catch {
                logger.warning("Failed to clean up \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `ps -axo command=`, or nil when it did not run cleanly.
    private static func runningCommands() -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
