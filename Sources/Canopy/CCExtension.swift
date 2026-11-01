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

    /// The newest extension in Canopy's folder, the only one `ExtensionUpdater` cross-checked.
    /// ~/.vscode/extensions is used only while Canopy's folder has none, so a newer copy there
    /// cannot take over from a checked one.
    static func extensionPath(canopyDir: URL = canopyExtensionsDir, vscodeDir: URL = vscodeExtensionsDir) -> URL? {
        guard let best = newest(folders(in: canopyDir)) ?? newest(folders(in: vscodeDir)) else {
            logger.error("CC extension not found in any known location")
            return nil
        }
        return best
    }

    /// The newest version in Canopy's own folder, nil when it holds none.
    static func canopyInstalledVersion(in dir: URL = canopyExtensionsDir) -> String? {
        newest(folders(in: dir)).flatMap(version(at:))
    }

    static var vscodeExtensionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions")
    }

    private static func newest(_ folders: [URL]) -> URL? {
        folders.max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending })
    }

    /// The installed folder holding `version`, so a page can match the extension host a session runs.
    static func installedPath(version: String) -> URL? {
        installedFolders().first { self.version(at: $0) == version }
    }

    private static func installedFolders() -> [URL] {
        folders(in: canopyExtensionsDir) + folders(in: vscodeExtensionsDir)
    }

    private static func folders(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix("anthropic.claude-code-") }
    }

    /// Read extension version from package.json (e.g., "2.1.87").
    static func extensionVersion() -> String? {
        extensionPath().flatMap(version(at:))
    }

    /// The `version` in an extension folder's package.json.
    static func version(at extPath: URL) -> String? {
        guard let data = try? Data(contentsOf: extPath.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
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
