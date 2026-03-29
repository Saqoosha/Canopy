import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "NodeDiscovery")

/// Discovers a suitable Node.js installation on the system (>= 18).
/// Checks Homebrew, mise, nvm, and login shell PATH.
enum NodeDiscovery {
    struct NodeInfo {
        let path: String
        let version: String
    }

    static func find() -> NodeInfo? {
        for candidate in candidatePaths() {
            if let info = validate(path: candidate) {
                logger.info("Found Node.js \(info.version) at \(info.path, privacy: .public)")
                return info
            }
        }
        logger.error("Node.js >= 18 not found. Install via Homebrew, mise, or nvm.")
        return nil
    }

    private static func candidatePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        // Homebrew
        paths.append("/opt/homebrew/bin/node")
        paths.append("/usr/local/bin/node")

        // mise shim
        paths.append("\(home)/.local/share/mise/shims/node")

        // mise direct installs (latest version)
        let miseDir = "\(home)/.local/share/mise/installs/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: miseDir) {
            if let latest = entries.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last {
                paths.append("\(miseDir)/\(latest)/bin/node")
            }
        }

        // nvm (latest version)
        let nvmDir = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            if let latest = entries.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last {
                paths.append("\(nvmDir)/\(latest)/bin/node")
            }
        }

        // Login shell `which` (catches other version managers)
        if let whichResult = shell("which node") {
            paths.append(whichResult)
        }

        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func validate(path: String) -> NodeInfo? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              output.hasPrefix("v")
        else { return nil }

        let version = String(output.dropFirst())
        let parts = version.split(separator: ".")
        guard let major = Int(parts.first ?? "0"), major >= 18 else {
            logger.warning("Node.js at \(path, privacy: .public) is v\(version) — need >= 18")
            return nil
        }

        return NodeInfo(path: path, version: version)
    }

    private static func shell(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
