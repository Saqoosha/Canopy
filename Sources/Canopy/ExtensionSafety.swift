import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ExtensionUpdater")

/// Starts a freshly downloaded Claude Code extension in a throwaway shim before Canopy adopts it.
/// Extension updates have broken activation in the shim more than once (#193, #276, #277); each
/// would have been caught here, before any session ran on the new version.
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
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [shimPath, "--extension-path", extensionDir.path, "--cwd", cwd.path,
                             "--settings-path", settings.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let buffer = OutputBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
        do {
            try process.run()
        } catch {
            return .failed("could not start the extension host: \(error.localizedDescription)")
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                // Read what the handler has not delivered yet, so the error frame written just
                // before `exit(1)` decides the verdict rather than the bare status.
                stdout.fileHandleForReading.readabilityHandler = nil
                buffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                return outcome(stdout: buffer.text, exitStatus: process.terminationStatus)
            }
            let verdict = outcome(stdout: buffer.text, exitStatus: nil)
            if verdict != .undecided { return verdict }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return .failed("the extension host did not become ready within \(Int(timeout)) s")
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

/// Removes old extension versions, but never one a running shim was started from: a daemon's
/// shims outlive the GUI that installed an update, and each one later spawns its CLI from
/// `resources/native-binary` inside its own version's folder.
enum ExtensionCleanup {
    /// The `--extension-path` of every running shim in `ps -axo command=` output. The path runs to
    /// the next ` --cwd`, since it contains spaces ("Application Support").
    static func extensionPathsInUse(psOutput: String) -> Set<String> {
        var paths = Set<String>()
        for line in psOutput.split(separator: "\n") {
            guard let start = line.range(of: "--extension-path ") else { continue }
            let rest = line[start.upperBound...]
            let path = rest.range(of: " --cwd ").map { rest[..<$0.lowerBound] } ?? rest
            paths.insert(String(path).trimmingCharacters(in: .whitespaces))
        }
        return paths
    }

    /// Entries of `dir` to delete: extension folders other than `keepingVersion` that no running shim uses.
    static func removable(installed: [String], in dir: String, keepingVersion: String, inUse: Set<String>) -> [String] {
        let keepPrefix = "anthropic.claude-code-\(keepingVersion)-"
        return installed.filter {
            $0.hasPrefix("anthropic.claude-code-") && !$0.hasPrefix(keepPrefix) && !inUse.contains("\(dir)/\($0)")
        }
    }

    /// Deletes what `removable` names in Canopy's extensions folder. Blocks on `ps`.
    static func removeUnused(keepingVersion: String) {
        let dir = CCExtension.canopyExtensionsDir
        guard let installed = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let inUse = extensionPathsInUse(psOutput: runningCommands())
        for name in removable(installed: installed, in: dir.path, keepingVersion: keepingVersion, inUse: inUse) {
            do {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                logger.notice("Cleaned up old extension: \(name, privacy: .public)")
            } catch {
                logger.warning("Failed to clean up \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let kept = installed.filter { inUse.contains("\(dir.path)/\($0)") && !$0.hasPrefix("anthropic.claude-code-\(keepingVersion)-") }
        if !kept.isEmpty {
            logger.notice("Kept \(kept.joined(separator: ", "), privacy: .public): a running session still uses it")
        }
    }

    private static func runningCommands() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
