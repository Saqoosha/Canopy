import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ExtensionUpdater")

@Observable
@MainActor
final class ExtensionUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(latestVersion: String, currentVersion: String?)
        case downloading
        case installing
        case done(version: String)
        case failed(message: String)
    }

    static let changelogURL = URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!

    private(set) var state: State = .idle

    func checkForUpdate() async {
        guard state == .idle || state == .upToDate || state.isTerminal else { return }

        state = .checking
        guard let latestVer = await marketplaceLatestVersion() else {
            logger.warning("Could not determine marketplace latest version")
            state = .idle
            return
        }
        guard Self.isValidVersion(latestVer) else {
            logger.error("Marketplace returned invalid version string: \(latestVer, privacy: .public)")
            state = .idle
            return
        }
        let extVer = CCExtension.extensionVersion()
        if let extVer, Self.compareVersions(extVer, latestVer) >= 0 {
            state = .upToDate
        } else {
            state = .updateAvailable(latestVersion: latestVer, currentVersion: extVer)
        }
    }

    /// Query the VS Marketplace for the latest published `anthropic.claude-code` version
    /// matching the current platform. Returns nil on network error or parse failure.
    private func marketplaceLatestVersion() async -> String? {
        let platform = Self.detectPlatform()
        let urlString = "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json;api-version=3.0-preview.1", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // flags=914 includes IncludeVersions + IncludeFiles + IncludeVersionProperties so each
        // version entry carries its targetPlatform.
        let body: [String: Any] = [
            "filters": [["criteria": [["filterType": 7, "value": "anthropic.claude-code"]]]],
            "flags": 914,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let extensions = results.first?["extensions"] as? [[String: Any]],
                  let versions = extensions.first?["versions"] as? [[String: Any]]
            else {
                logger.warning("Marketplace query: unexpected response shape")
                return nil
            }
            // Versions are returned newest-first. Prefer the first entry matching our platform.
            for v in versions {
                if let version = v["version"] as? String,
                   v["targetPlatform"] as? String == platform,
                   Self.isValidVersion(version)
                {
                    return version
                }
            }
            return nil
        } catch {
            logger.warning("Marketplace query failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func triggerInstall() async {
        guard case .updateAvailable(let version, _) = state else { return }
        await installUpdate(version: version)
    }

    private func installUpdate(version: String) async {
        state = .downloading
        do {
            let vsixURL = try await downloadVSIX(version: version)
            state = .installing
            try await installVSIX(at: vsixURL, version: version)
            cleanupOldVersions(keeping: version)
            state = .done(version: version)
        } catch {
            state = .failed(message: error.localizedDescription)
            logger.error("Extension update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Download

    private func downloadVSIX(version: String) async throws -> URL {
        let platform = Self.detectPlatform()
        let urlString = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/\(version)/vspackage?targetPlatform=\(platform)"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }
        logger.info("Downloading extension v\(version, privacy: .public) from marketplace")
        let (localURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.downloadFailed(statusCode: code)
        }
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-\(version)-\(UUID().uuidString.prefix(8)).vsix")
        try FileManager.default.moveItem(at: localURL, to: destURL)
        return destURL
    }

    // MARK: - Install

    private func installVSIX(at vsixURL: URL, version: String) async throws {
        let canopyExtensionsDir = CCExtension.canopyExtensionsDir
        let task = Task.detached(priority: .userInitiated) {
            let platform = Self.detectPlatform()
            let extensionsDir = canopyExtensionsDir
            let targetDir = extensionsDir
                .appendingPathComponent("anthropic.claude-code-\(version)-\(platform)")

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cc-ext-\(version)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let stderrPipe = Pipe()
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", vsixURL.path, "extension/*", "-d", tempDir.path]
            unzip.standardOutput = Pipe()
            unzip.standardError = stderrPipe
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errOutput = String(data: errData, encoding: .utf8) ?? ""
                logger.error("unzip failed (status \(unzip.terminationStatus)): \(errOutput, privacy: .public)")
                throw UpdateError.extractionFailed
            }

            let extractedExt = tempDir.appendingPathComponent("extension")
            guard FileManager.default.fileExists(atPath: extractedExt.path) else {
                throw UpdateError.extractionFailed
            }

            try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetDir.path) {
                do {
                    try FileManager.default.removeItem(at: targetDir)
                } catch {
                    logger.warning("Could not remove existing extension at \(targetDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            try FileManager.default.moveItem(at: extractedExt, to: targetDir)
            try? FileManager.default.removeItem(at: vsixURL)

            logger.info("Extension v\(version, privacy: .public) installed at: \(targetDir.path, privacy: .public)")
        }
        try await task.value
    }

    // MARK: - Cleanup

    private func cleanupOldVersions(keeping currentVersion: String) {
        let extensionsDir = CCExtension.canopyExtensionsDir
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir.path) else { return }
        let keepPrefix = "anthropic.claude-code-\(currentVersion)-"
        for name in contents where name.hasPrefix("anthropic.claude-code-") && !name.hasPrefix(keepPrefix) {
            let fullPath = extensionsDir.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: fullPath)
                logger.info("Cleaned up old extension: \(name, privacy: .public)")
            } catch {
                logger.warning("Failed to clean up \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Platform Detection

    private nonisolated static func detectPlatform() -> String {
        let searchDirs = [
            CCExtension.canopyExtensionsDir,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions"),
        ]
        for dir in searchDirs {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               let existing = contents.first(where: { $0.hasPrefix("anthropic.claude-code-") })
            {
                // Match known platform suffixes at end of directory name
                let knownPlatforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]
                if let platform = knownPlatforms.first(where: { existing.hasSuffix($0) }) {
                    return platform
                }
            }
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine == "arm64" ? "darwin-arm64" : "darwin-x64"
    }

    // MARK: - Version Validation & Comparison

    private static func isValidVersion(_ v: String) -> Bool {
        let parts = v.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Compare two semver strings. Returns negative if a < b, 0 if equal, positive if a > b.
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av - bv }
        }
        return 0
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidURL
        case downloadFailed(statusCode: Int)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid marketplace URL"
            case .downloadFailed(let code): return "Download failed (HTTP \(code))"
            case .extractionFailed: return "Failed to extract extension package"
            }
        }
    }
}

extension ExtensionUpdater.State {
    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}
