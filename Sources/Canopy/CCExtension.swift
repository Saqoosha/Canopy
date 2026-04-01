import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CCExtension")

/// Shared utilities for finding Claude Code extension and CLI binary.
enum CCExtension {
    /// Canopy-managed extension directory (preferred over ~/.vscode/extensions).
    static var canopyExtensionsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canopy/extensions")
    }

    /// Find the newest installed CC extension path across all known locations.
    static func extensionPath() -> URL? {
        let searchDirs = [
            canopyExtensionsDir,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions"),
        ]
        var allCandidates: [URL] = []
        for dir in searchDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            allCandidates.append(contentsOf: contents.filter {
                $0.lastPathComponent.hasPrefix("anthropic.claude-code-")
            })
        }
        guard let best = allCandidates
            .max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending })
        else {
            logger.error("CC extension not found in any known location")
            return nil
        }
        return best
    }

    /// Read extension version from package.json (e.g., "2.1.87").
    static func extensionVersion() -> String? {
        guard let extPath = extensionPath() else { return nil }
        let packageJSON = extPath.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String
        else { return nil }
        return version
    }

    /// Get the actual CLI binary version by running `claude --version`.
    /// Uses Task.detached + waitUntilExit to avoid pipe deadlock (same pattern as NodeDiscovery).
    static func cliVersion() async -> String? {
        guard let cliPath = cliBinaryPath() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = cliPath
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                logger.error("Failed to run claude --version: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Parse "2.1.89 (Claude Code)" → "2.1.89"
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first
            return version?.isEmpty == false ? version : nil
        }.value
    }

    /// Find the Claude CLI binary, checking common install locations.
    static func cliBinaryPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        logger.error("Claude CLI not found in: \(candidates, privacy: .public)")
        return nil
    }
}
