import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteSessionsBridge")

struct RemoteSession: Identifiable, Hashable, Sendable {
    let id: String
    let summary: String
    let lastModified: Date
    let status: String
    let repoOwner: String?
    let repoName: String?
    let branch: String?
    let kind: RemoteSessionKind
    let origin: String?
    let cwd: String?

    var displayBranch: String? {
        guard let branch, !branch.isEmpty, branch != "HEAD" else { return nil }
        return branch
    }

    var isRunning: Bool { status == "running" }
}

struct TeleportResult: Sendable {
    let localSessionId: String?
    let branch: String?
    let messageCount: Int?
    let summary: String?
}

enum RemoteSessionsBridgeError: Error, LocalizedError {
    case nodeNotFound
    case shimNotFound
    case extensionNotFound
    case spawnFailed(String)
    case timeout(String)
    case protocolError(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: "Node.js >= 18 not found"
        case .shimNotFound: "vscode-shim not found in app bundle"
        case .extensionNotFound: "Claude Code extension not found"
        case .spawnFailed(let m): "Failed to spawn shim: \(m)"
        case .timeout(let m): "Timed out: \(m)"
        case .protocolError(let m): "Protocol error: \(m)"
        case .requestFailed(let m): "Request failed: \(m)"
        }
    }
}

/// Spawns a short-lived vscode-shim process to call list_remote_sessions / teleport_session.
/// The shim auto-activates the CC extension; auth tokens are read from the shared
/// file-backed Secrets store, so the user must already be OAuth-logged-in via Canopy.
/// One bridge instance owns one Node subprocess. Call shutdown() when done.
///
/// Thread safety: mutable state is touched only from the main thread. Stdout/stderr
/// readability handlers dispatch to main; stdin writes serialize via writeQueue.
final class RemoteSessionsBridge: @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    private var ready = false
    private var didShutdown = false
    private var pendingResponses: [String: CheckedContinuation<JSONBox, Error>] = [:]
    private var pendingReady: CheckedContinuation<Void, Error>?

    /// Sendable wrapper for response dictionaries. We parse them on the consumer
    /// side; the underlying JSON dictionary is treated as immutable post-resume.
    private struct JSONBox: @unchecked Sendable {
        let dict: [String: Any]
    }
    private let writeQueue = DispatchQueue(label: "sh.saqoo.Canopy.remoteSessionsBridgeWrite")

    private let cwd: URL
    private let env: [String: String]

    init(cwd: URL, extraEnv: [String: String] = [:]) {
        self.cwd = cwd
        var e = ProcessInfo.processInfo.environment
        e["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        for (k, v) in extraEnv { e[k] = v }
        self.env = e
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Lifecycle

    /// Spawn the shim and wait until it sends `{type:"ready"}`.
    func start() async throws {
        guard process == nil else { return }

        guard let nodeInfo = NodeDiscovery.find() else {
            throw RemoteSessionsBridgeError.nodeNotFound
        }
        guard let shimPath = ShimProcess.findShimPath() else {
            throw RemoteSessionsBridgeError.shimNotFound
        }
        guard let extPath = CCExtension.extensionPath()?.path else {
            throw RemoteSessionsBridgeError.extensionNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeInfo.path)
        proc.arguments = [
            shimPath,
            "--extension-path", extPath,
            "--cwd", cwd.path,
            "--settings-path", CanopySettings.shared.filePath.path,
        ]
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Strong capture: bridge is short-lived; closures release once the
        // subprocess exits or shutdown() nils the handlers.
        let selfRef = self
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                if selfRef.process?.isRunning != true {
                    handle.readabilityHandler = nil
                }
                return
            }
            DispatchQueue.main.async {
                selfRef.handleStdout(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // Only nil on true EOF — spurious empty reads from a still-running
                // process would otherwise permanently kill the handler mid-session.
                if selfRef.process?.isRunning != true {
                    handle.readabilityHandler = nil
                }
                return
            }
            if let str = String(data: data, encoding: .utf8) {
                for line in str.split(separator: "\n") {
                    logger.debug("[shim:stderr] \(line, privacy: .public)")
                }
            }
        }

        proc.terminationHandler = { p in
            logger.info("RemoteSessionsBridge shim exited status=\(p.terminationStatus)")
            DispatchQueue.main.async {
                // shutdown() may have already drained continuations; check.
                guard !selfRef.didShutdown else { return }
                if let cont = selfRef.pendingReady {
                    selfRef.pendingReady = nil
                    cont.resume(throwing: RemoteSessionsBridgeError.spawnFailed("shim exited with status \(p.terminationStatus) before ready"))
                }
                for (_, cont) in selfRef.pendingResponses {
                    cont.resume(throwing: RemoteSessionsBridgeError.requestFailed("shim exited (status \(p.terminationStatus))"))
                }
                selfRef.pendingResponses.removeAll()
            }
        }

        do {
            try proc.run()
        } catch {
            throw RemoteSessionsBridgeError.spawnFailed(error.localizedDescription)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.pendingReady = cont
            // Safety timeout: if we never see "ready" within 30s, fail
            let selfRef = self
            let timeoutTask = DispatchWorkItem {
                guard let pending = selfRef.pendingReady else { return }
                selfRef.pendingReady = nil
                pending.resume(throwing: RemoteSessionsBridgeError.timeout("waiting for shim ready"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeoutTask)
        }

        // After ready, send webview_ready so extension activates fully
        send(["type": "webview_ready"])
    }

    func shutdown() {
        // Idempotent + race-safe: terminationHandler may also drain
        // continuations; the flag guards against double-resume.
        guard !didShutdown else { return }
        didShutdown = true
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Best-effort: give it 1s, then SIGKILL if still running.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        pendingReady?.resume(throwing: RemoteSessionsBridgeError.requestFailed("bridge shut down"))
        pendingReady = nil
        for (_, cont) in pendingResponses {
            cont.resume(throwing: RemoteSessionsBridgeError.requestFailed("bridge shut down"))
        }
        pendingResponses.removeAll()
    }

    // MARK: - Public API

    /// Fetch remote sessions visible to the current OAuth token. The extension
    /// auto-filters by the cwd's git origin URL (or returns all sessions if cwd
    /// is not a git repo).
    func listRemoteSessions(timeoutSeconds: TimeInterval = 30) async throws -> [RemoteSession] {
        let response = try await sendRequest(type: "list_remote_sessions", timeout: timeoutSeconds)
        let sessions = (response["sessions"] as? [[String: Any]]) ?? []
        let parsed = sessions.compactMap(Self.parseRemoteSession)
        logger.info("list_remote_sessions returned \(parsed.count) session(s) (raw=\(sessions.count))")
        return parsed
    }

    /// Fetch a remote session, save it locally as JSONL, return localSessionId + branch.
    /// If the response carries a `branch`, the caller should ask the user whether to
    /// checkout (call `checkoutBranch`) or skip (call `updateSkippedBranch`).
    func teleportSession(id: String, timeoutSeconds: TimeInterval = 60) async throws -> TeleportResult {
        let response = try await sendRequest(
            type: "teleport_session",
            extraFields: ["sessionId": id],
            timeout: timeoutSeconds
        )
        return TeleportResult(
            localSessionId: response["localSessionId"] as? String,
            branch: response["branch"] as? String,
            messageCount: response["messageCount"] as? Int,
            summary: response["summary"] as? String
        )
    }

    func checkoutBranch(_ branch: String) async throws -> Bool {
        let response = try await sendRequest(
            type: "checkout_branch",
            extraFields: ["branch": branch]
        )
        return (response["success"] as? Bool) ?? false
    }

    func updateSkippedBranch(sessionId: String, branch: String, failed: Bool) async throws {
        _ = try await sendRequest(
            type: "update_skipped_branch",
            extraFields: ["sessionId": sessionId, "branch": branch, "failed": failed]
        )
    }

    // MARK: - Request/Response

    private func sendRequest(
        type: String,
        extraFields: [String: Any] = [:],
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        guard process?.isRunning == true else {
            throw RemoteSessionsBridgeError.requestFailed("bridge process is not running")
        }
        let requestId = "canopy-remote-\(UUID().uuidString.prefix(8))"
        var requestPayload: [String: Any] = ["type": type]
        for (k, v) in extraFields { requestPayload[k] = v }

        let envelope: [String: Any] = [
            "type": "webview_message",
            "message": [
                "type": "request",
                "channelId": "canopy-remote",
                "requestId": requestId,
                "request": requestPayload,
            ] as [String: Any],
        ]

        let box = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONBox, Error>) in
            self.pendingResponses[requestId] = cont
            self.send(envelope)

            let selfRef = self
            let timeoutTask = DispatchWorkItem {
                guard let pending = selfRef.pendingResponses.removeValue(forKey: requestId) else { return }
                pending.resume(throwing: RemoteSessionsBridgeError.timeout("\(type) (\(Int(timeout))s)"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        }
        return box.dict
    }

    private func send(_ msg: [String: Any]) {
        // JSON-encode on the calling thread (main), then hand the bytes to the
        // serial write queue. This avoids accessing `msg` (non-Sendable) inside
        // a Sendable closure and keeps stdin writes serialized.
        guard let pipe = stdinPipe else { return }
        let data: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: msg)
            encoded.append(0x0A) // newline
            data = encoded
        } catch {
            logger.error("send: JSON encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        writeQueue.async {
            do {
                try pipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                logger.error("send: write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Stdout parsing

    private func handleStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            handleMessage(json)
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        let type = msg["type"] as? String

        if type == "ready", let cont = pendingReady {
            ready = true
            pendingReady = nil
            cont.resume()
            return
        }

        // Webview-bound responses are wrapped: {type:"webview_message", message:{type:"response"|"from-extension", ...}}
        guard type == "webview_message" else { return }
        guard let outer = msg["message"] as? [String: Any] else { return }

        let inner: [String: Any]
        if outer["type"] as? String == "from-extension",
           let nested = outer["message"] as? [String: Any] {
            inner = nested
        } else {
            inner = outer
        }

        guard inner["type"] as? String == "response",
              let requestId = inner["requestId"] as? String
        else { return }

        guard let cont = pendingResponses.removeValue(forKey: requestId) else { return }

        if let err = inner["error"] as? String {
            cont.resume(throwing: RemoteSessionsBridgeError.requestFailed(err))
            return
        }
        let response = (inner["response"] as? [String: Any]) ?? inner
        cont.resume(returning: JSONBox(dict: response))
    }

    // MARK: - Parsing

    private static func parseRemoteSession(_ raw: [String: Any]) -> RemoteSession? {
        guard let id = raw["id"] as? String else { return nil }
        let summary = (raw["summary"] as? String) ?? "Untitled"
        let lastModifiedMs = (raw["lastModified"] as? Double) ?? 0
        let status = (raw["status"] as? String) ?? "idle"
        let repo = raw["remoteRepo"] as? [String: Any]
        // Extension-stripped responses don't carry env_id/cwd/origin, so we can't
        // classify reliably here. Default to .web — callers that need real
        // classification should use RemoteSessionsAPI.listAll() instead.
        return RemoteSession(
            id: id,
            summary: summary,
            lastModified: Date(timeIntervalSince1970: lastModifiedMs / 1000),
            status: status,
            repoOwner: repo?["owner"] as? String,
            repoName: repo?["name"] as? String,
            branch: repo?["branch"] as? String,
            kind: .web,
            origin: nil,
            cwd: nil
        )
    }
}
