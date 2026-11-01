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
        /// Newer than what Canopy has installed, waiting for a click because auto-update is off.
        case available(version: String)
        case downloading
        case installing
        case done(version: String)
        case failed(message: String)
    }

    /// One per process: every launcher pane checks on appear, and an update now installs
    /// without a click, so per-pane instances would race two installs into one folder.
    static let shared = ExtensionUpdater()

    /// Everything the updater reaches outside itself, so the probe can drive it with no network
    /// and without touching the real extensions folder.
    struct Environment {
        var latestVersion: @MainActor (ExtensionUpdater) async -> String?
        var installedVersion: @MainActor () -> String?
        var autoUpdate: @MainActor () -> Bool
        var publishedDigest: @MainActor (_ version: String, _ platform: String) async -> String?
        var download: @MainActor (ExtensionUpdater, _ version: String) async throws -> URL
        var install: @MainActor (ExtensionUpdater, _ vsix: URL, _ version: String) async throws -> Void
        var notify: @MainActor (_ title: String, _ body: String) -> Void

        static var live: Environment {
            Environment(
                latestVersion: { await $0.marketplaceLatestVersion() },
                // Canopy's own folder only: a version in ~/.vscode/extensions was not cross-checked.
                installedVersion: { CCExtension.canopyInstalledVersion() },
                autoUpdate: { CanopySettings.shared.autoUpdateExtension },
                publishedDigest: { await ExtensionCrossCheck.publishedSHA256(version: $0, platform: $1) },
                download: { try await $0.downloadVSIX(version: $1) },
                install: { updater, vsix, version in
                    try await updater.installVSIX(at: vsix, version: version)
                    await Task.detached(priority: .utility) { ExtensionCleanup.removeUnused() }.value
                },
                notify: { SessionNotifier.post(title: $0, body: $1, showWhileFrontmost: true) }
            )
        }
    }

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// The last failed install in this process. That version is not installed again without a click.
    private var failure: (version: String, message: String)?

    private(set) var state: State = .idle

    /// How far the VSIX download has got. Non-nil only while `state` is
    /// `.downloading`, and even then nil until the first poll lands.
    private(set) var downloadProgress: DownloadProgress?

    struct DownloadProgress: Equatable {
        var received: Int64
        /// The response's `Content-Length`, nil when the server sent none.
        var total: Int64?

        /// Decoded bytes over the gzip-encoded Content-Length, clamped.
        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }
    }

    /// `retryingFailure` is the banner's Retry: a click is consent to try the failed version again.
    func checkForUpdate(retryingFailure: Bool = false) async {
        guard state.allowsCheck else { return }

        state = .checking
        // A failed lookup keeps a stored failure, and its Retry, on screen.
        let fallback: State = failure.map { .failed(message: $0.message) } ?? .idle
        guard let latestVer = await environment.latestVersion(self) else {
            logger.warning("Could not determine marketplace latest version")
            state = fallback
            return
        }
        guard Self.isValidVersion(latestVer) else {
            logger.error("Marketplace returned invalid version string: \(latestVer, privacy: .public)")
            state = fallback
            return
        }
        let extVer = environment.installedVersion()
        if let extVer, Self.compareVersions(extVer, latestVer) >= 0 {
            state = .upToDate
        } else if let failure, failure.version == latestVer, !retryingFailure {
            // Terminal, so a later mount still checks and picks up a fixed newer version.
            state = .failed(message: failure.message)
        } else if !retryingFailure, !environment.autoUpdate() {
            state = .available(version: latestVer)
        } else {
            // New sessions pick the newest installed version at spawn, so installing is all an update takes.
            await installUpdate(version: latestVer, automatic: !retryingFailure)
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

    /// The banner's Install, for the version `checkForUpdate` offered with auto-update off.
    func installAvailable() async {
        guard case .available(let version) = state else { return }
        await installUpdate(version: version, automatic: false)
    }

    private func installUpdate(version: String, automatic: Bool) async {
        // Busy before the first await, so a second click or another pane's check cannot start a second install.
        state = .checking
        // Looked up before the download: Open VSX can lag the VS Marketplace, and this is not a failure.
        guard let published = await environment.publishedDigest(version, Self.detectPlatform()) else {
            logger.notice("Extension v\(version, privacy: .public): no digest from Open VSX (not listed yet, or unreachable), update deferred")
            // Offered, not hidden, so a lasting outage shows. Not stored in `failure`: the next check tries again.
            state = automatic
                ? .available(version: version)
                : .failed(message: "Open VSX has no digest for v\(version) yet, or could not be reached, so it cannot be cross-checked. Try again later.")
            return
        }
        state = .downloading
        var vsixURL: URL?
        defer { if let vsixURL { try? FileManager.default.removeItem(at: vsixURL) } }
        do {
            let vsix = try await environment.download(self, version)
            vsixURL = vsix
            let downloaded = try await Task.detached(priority: .userInitiated) {
                try ExtensionCrossCheck.sha256(of: vsix)
            }.value
            if case .mismatch = ExtensionCrossCheck.verdict(downloaded: downloaded, published: published) {
                logger.fault("Extension v\(version, privacy: .public): VS Marketplace VSIX \(downloaded, privacy: .public) does not match Open VSX \(published, privacy: .public)")
                throw UpdateError.crossCheckMismatch(version: version)
            }
            state = .installing
            try await environment.install(self, vsix, version)
            failure = nil
            state = .done(version: version)
            // The install needs no click now, so the launcher banner may never be on screen.
            environment.notify("Claude Code extension updated", "v\(version) is installed. New sessions use it.")
        } catch {
            failure = (version, error.localizedDescription)
            state = .failed(message: error.localizedDescription)
            // A Retry click already has the banner in front of it.
            if automatic {
                environment.notify("Claude Code extension update failed", "v\(version): \(error.localizedDescription)")
            }
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
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-\(version)-\(UUID().uuidString.prefix(8)).vsix")

        // A task handle, not `download(from:)`, which hides its byte counts.
        var task: URLSessionDownloadTask?
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let task, let self {
                    // The header, not `expectedContentLength`: that is -1 under gzip.
                    let header = (task.response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Content-Length")
                    let progress = DownloadProgress(
                        received: task.countOfBytesReceived,
                        total: header.flatMap { Int64($0) }
                    )
                    if progress != self.downloadProgress { self.downloadProgress = progress }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            poller.cancel()
            downloadProgress = nil
        }

        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            let downloadTask = Self.makeDownloadTask(url: url, movingTo: destURL, continuation: continuation)
            task = downloadTask
            downloadTask.resume()
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            try? FileManager.default.removeItem(at: destURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.downloadFailed(statusCode: code)
        }
        return destURL
    }

    /// The downloaded file only exists until the completion returns, so it is moved there.
    private nonisolated static func makeDownloadTask(
        url: URL, movingTo destURL: URL,
        continuation: CheckedContinuation<URLResponse, Error>
    ) -> URLSessionDownloadTask {
        URLSession.shared.downloadTask(with: url) { localURL, response, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let localURL, let response else {
                continuation.resume(throwing: URLError(.badServerResponse))
                return
            }
            do {
                try FileManager.default.moveItem(at: localURL, to: destURL)
                continuation.resume(returning: response)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Install

    private func installVSIX(at vsixURL: URL, version: String) async throws {
        let canopyExtensionsDir = CCExtension.canopyExtensionsDir
        let nodePath = NodeDiscovery.find()?.path
        let shimPath = ShimProcess.findShimPath()
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

            // Before it can become the version new sessions pick: a failure leaves nothing installed.
            if let nodePath, let shimPath {
                let verdict = ExtensionCanary.run(extensionDir: extractedExt, nodePath: nodePath, shimPath: shimPath)
                guard verdict == .passed else {
                    let reason = if case .failed(let message) = verdict { message } else { "no verdict" }
                    logger.error("Extension v\(version, privacy: .public) failed its start check: \(reason, privacy: .public)")
                    throw UpdateError.canaryFailed(version: version, reason: reason)
                }
                logger.notice("Extension v\(version, privacy: .public) passed its start check")
            } else {
                // Installing unchecked would also let cleanup remove the known-good version.
                logger.error("Extension v\(version, privacy: .public): not installed, node or the shim was not found for the start check")
                throw UpdateError.canaryFailed(version: version, reason: "Node.js or Canopy's shim was not found, so it could not be checked")
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

            logger.info("Extension v\(version, privacy: .public) installed at: \(targetDir.path, privacy: .public)")
        }
        try await task.value
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
        case canaryFailed(version: String, reason: String)
        case crossCheckMismatch(version: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid marketplace URL"
            case .downloadFailed(let code): return "Download failed (HTTP \(code))"
            case .extractionFailed: return "Failed to extract extension package"
            case .canaryFailed(let version, let reason):
                return "v\(version) did not start in Canopy, so it was not installed: \(reason)"
            case .crossCheckMismatch(let version):
                return "v\(version) from the VS Marketplace differs from the copy on Open VSX, so it was not installed and Canopy keeps the version it has. One of them may have been tampered with."
            }
        }
    }
}

extension ExtensionUpdater.State {
    /// Not while a check or an install is running. `.available` rechecks, so a newer release replaces the offer.
    var allowsCheck: Bool {
        switch self {
        case .idle, .upToDate, .available, .done, .failed: return true
        case .checking, .downloading, .installing: return false
        }
    }
}
