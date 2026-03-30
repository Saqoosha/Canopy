import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "CCExtension")

/// Shared utilities for finding Claude Code extension and CLI binary.
enum CCExtension {
    /// Find the latest installed CC extension path.
    static func extensionPath() -> URL? {
        let extensionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions")
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: extensionsDir, includingPropertiesForKeys: nil
            )
            return contents
                .filter { $0.lastPathComponent.hasPrefix("anthropic.claude-code-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .first
        } catch {
            logger.error("Failed to read extensions directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
