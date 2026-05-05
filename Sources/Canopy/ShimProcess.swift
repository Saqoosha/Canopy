import Cocoa
import UserNotifications
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ShimProcess")

@MainActor
protocol ShimProcessDelegate: AnyObject {
    func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String)
    func shimProcessDidCrash(_ shim: ShimProcess, status: Int32)
}

/// Manages a Node.js subprocess running the vscode-shim that bridges the CC extension
/// to Canopy's WKWebView via stdin/stdout NDJSON.
///
/// Thread safety: `stdoutBuffer` is only accessed from the stdout readabilityHandler
/// (serialized by the system). All other mutable state (`isReady`, `pendingMessages`, etc.)
/// is only accessed from the main thread. Stdin writes are serialized via `writeQueue`.
final class ShimProcess: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var webView: WKWebView?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set when shim sends {"type":"ready"} — extension is activated and providers are set up.
    private var isReady = false
    /// Messages queued before the shim is ready (flushed on "ready").
    private var pendingMessages: [[String: Any]] = []

    /// Accumulates partial lines from stdout (only accessed from readabilityHandler thread).
    private var stdoutBuffer = Data()
    /// Descendant PIDs collected before termination, used for cleanup on unexpected exit.
    private var descendantPids: [pid_t] = []
    /// Channel ID from launch_claude, needed for generate_session_title requests.
    private var channelId: String?
    /// Counts user messages since the last AI title generation attempt.
    /// Starts at `titleRefreshInterval` so the first user message triggers an immediate request.
    private var userMessagesSinceLastTitle = 4
    /// Generate a fresh AI title every N user messages.
    private let titleRefreshInterval = 4
    /// True after an AI-generated title (or fallback) has been applied.
    /// Blocks raw webview title overwrites until the next title request cycle.
    private var hasGeneratedTitle = false
    /// True while a `generate_session_title` request is awaiting a response.
    private var titleRequestInFlight = false
    /// Request ID of the current title generation, used to reject stale responses.
    private var currentTitleRequestId: String?
    /// Most recent user message text, used as fallback when AI generation doesn't respond.
    private var lastUserMessageText: String?
    /// Session ID from webview's update_session_state, used to persist generated titles.
    private var activeSessionId: String?
    /// Generated title waiting to be saved (when activeSessionId arrives after the title response).
    private var pendingGeneratedTitle: String?

    private let writeQueue = DispatchQueue(label: "sh.saqoo.Canopy.shimWrite")

    /// All living ShimProcess instances (weak references, auto-removed on dealloc).
    @MainActor private static var instances = NSHashTable<ShimProcess>.weakObjects()

    /// Whether any shim process is currently running. Used by AppDelegate's
    /// quit-time confirmation alert. `isIntentionalStop` shims are excluded —
    /// `proc.terminate()` is async, so `process.isRunning` lingers true for a
    /// few ms after `stop()` returns and would otherwise trip the prompt.
    @MainActor static var hasActiveSession: Bool {
        instances.allObjects.contains { $0.process?.isRunning == true && !$0.isIntentionalStop }
    }

    /// Number of currently running shim processes (excluding ones already in
    /// the middle of an intentional `stop()`).
    @MainActor static var activeCount: Int {
        instances.allObjects.filter { $0.process?.isRunning == true && !$0.isIntentionalStop }.count
    }

    /// Synchronously stop any running shim that no `OpenSession` still
    /// owns (e.g. orphaned by an SSH reconnect mid-flight). Called as a
    /// cleanup pass from `applicationShouldTerminate` so leftover Node.js
    /// processes don't trigger a spurious "session still running" prompt
    /// at quit time.
    ///
    /// We can't use "webView detached from a window" as the orphan signal
    /// here: in the sidebar shell, inactive open sessions cache their
    /// WKWebView on `OpenSession.webView` with `.window == nil` — they're
    /// legitimate background sessions, not orphans, and killing them on
    /// quit would skip the terminate-confirmation alert. Ownership is the
    /// honest signal: a shim whose `boundSession` is gone, or whose
    /// `boundSession.shim` is now a *different* instance (SSH reconnect
    /// replaced it), is what we actually want to clean up.
    @MainActor static func stopOrphanedSessions() {
        for shim in instances.allObjects {
            let session = shim.boundSession
            if session == nil || session?.shim !== shim {
                shim.stop()
            }
        }
    }

    let workingDirectory: URL
    var resumeSessionId: String?
    var model: String?
    var effortLevel: String?
    var permissionMode: PermissionMode
    var remoteHost: String?
    var customApi: ModelProvider?

    // MARK: - Activity tracking (drives sidebar spinner via boundSession.isThinking)
    private var sessionTitle: String = ""
    private var isWorking = false {
        didSet {
            // When Claude starts a new round (user submitted), clear any
            // outstanding AskUserQuestion asking state — the user already
            // responded, we're back to thinking.
            if isWorking && !oldValue {
                lastAssistantHadAskUserQuestion = false
                refreshAskingState()
            }
            boundSession?.isThinking = isWorking
        }
    }

    /// True when the most recent assistant message contained a
    /// `tool_use` block whose name is `AskUserQuestion`. Drives `isAsking`
    /// once the result event fires and `isWorking` goes false.
    private var lastAssistantHadAskUserQuestion = false

    /// Optional OpenSession that owns this shim. Set by WebViewContainer
    /// after spawn so isWorking transitions reach the sidebar's icon.
    weak var boundSession: OpenSession?

    /// In-flight `tool_permission_request` ids from extension → webview.
    /// When non-empty the user is being asked to approve something; the
    /// sidebar shows a "raised hand" icon while at least one is outstanding.
    private var pendingPermissionRequestIds = Set<String>()

    var statusBarData: StatusBarData?
    weak var delegate: ShimProcessDelegate?
    private var isIntentionalStop = false

    @MainActor
    init(workingDirectory: URL, resumeSessionId: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, sessionTitle: String? = nil, statusBarData: StatusBarData? = nil, remoteHost: String? = nil, customApi: ModelProvider? = nil) {
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
        self.model = model
        self.effortLevel = effortLevel
        self.permissionMode = permissionMode
        self.sessionTitle = sessionTitle ?? ""
        self.statusBarData = statusBarData
        self.remoteHost = remoteHost
        self.customApi = customApi
        super.init()
        Self.instances.add(self)
        // Set CLI version, VCS branch, initial message count, and remote host
        statusBarData?.cliVersion = CCExtension.extensionVersion() ?? ""
        statusBarData?.remoteHost = remoteHost
        let dir = workingDirectory
        nonisolated(unsafe) let barData = statusBarData
        DispatchQueue.global(qos: .utility).async {
            guard let vcsInfo = Self.detectVCSInfo(at: dir) else { return }
            DispatchQueue.main.async {
                barData?.vcsType = vcsInfo.type
                barData?.gitBranch = vcsInfo.branch
            }
        }
        // Restore cached context limits for immediate display on session resume
        let cachedMax = UserDefaults.standard.integer(forKey: "statusBar.contextMax.\(workingDirectory.path)")
        if cachedMax > 0 { statusBarData?.contextMax = cachedMax }
        let cachedMaxOutput = UserDefaults.standard.integer(forKey: "statusBar.maxOutputTokens.\(workingDirectory.path)")
        if cachedMaxOutput > 0 { statusBarData?.maxOutputTokens = cachedMaxOutput }
        if let sessionId = resumeSessionId {
            statusBarData?.messageCount = ClaudeSessionHistory.countMessages(
                sessionId: sessionId, directory: workingDirectory
            )
        }
    }

    // MARK: - Lifecycle

    /// Start the Node.js shim subprocess. Returns false if startup fails.
    @discardableResult
    func start() -> Bool {
        guard process == nil else {
            logger.warning("start() called while already running")
            return true
        }

        guard let nodeInfo = NodeDiscovery.find() else {
            logger.error("Cannot start shim: Node.js >= 18 not found")
            showErrorInWebView("Node.js >= 18 not found. Install via Homebrew, mise, or nvm.")
            return false
        }

        guard let shimPath = Self.findShimPath() else {
            logger.error("Cannot find vscode-shim/index.js")
            showErrorInWebView("vscode-shim not found in app bundle.")
            return false
        }

        guard let extensionPath = CCExtension.extensionPath()?.path else {
            logger.error("Cannot start shim: CC extension not found")
            showErrorInWebView("Claude Code extension not found. Install it in VSCode first.")
            return false
        }

        // Verify the working directory exists before starting the shim.
        // Skip for SSH remote sessions — the path is on the remote machine.
        if remoteHost == nil {
            let cwdPath = workingDirectory.path
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir) || !isDir.boolValue {
                logger.error("Working directory does not exist: \(cwdPath, privacy: .public)")
                showErrorInWebView("Directory not found: \(cwdPath)")
                return false
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeInfo.path)

        var args = [shimPath, "--extension-path", extensionPath, "--cwd", workingDirectory.path]
        if let sessionId = resumeSessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }
        args.append(contentsOf: ["--permission-mode", permissionMode.rawValue])
        args.append(contentsOf: ["--settings-path", CanopySettings.shared.filePath.path])
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path

        // Ensure PATH includes directories where tools like rg (ripgrep) live.
        // macOS GUI apps inherit a minimal PATH (/usr/bin:/bin:...). We prepend the
        // Node.js binary's directory (which may come from mise/nvm) and Homebrew paths.
        // The CC extension uses system rg for @-mention file listing with gitignore support.
        let nodeBinDir = (nodeInfo.path as NSString).deletingLastPathComponent
        var extraPaths = [nodeBinDir]
        // Homebrew (Apple Silicon and Intel)
        for p in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if !extraPaths.contains(p) { extraPaths.append(p) }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingPaths = Set(currentPath.split(separator: ":").map(String.init))
        let newPaths = extraPaths.filter { !existingPaths.contains($0) }
        if !newPaths.isEmpty {
            env["PATH"] = (newPaths + [currentPath]).joined(separator: ":")
        }

        // Write model/effort to ~/.claude/settings.json before CLI starts
        Self.applyClaudeSettings([("model", model), ("effortLevel", effortLevel)])

        // SSH remote: pass wrapper path via env var (per-shim, not the shared
        // settings file). Writing to the settings file caused cross-window
        // interference and broke /resume when the wrapper was eagerly cleared
        // after the first CLI spawn.
        if let remote = remoteHost {
            guard let wrapperPath = Self.findWrapperPath() else {
                logger.error("SSH remote: wrapper script not found in bundle")
                showErrorInWebView("SSH remote mode failed: wrapper script not found. Try reinstalling Canopy.")
                return false
            }
            env["CANOPY_SSH_HOST"] = remote
            env["CANOPY_SSH_CWD"] = workingDirectory.path
            env["CANOPY_SSH_WRAPPER_PATH"] = wrapperPath
            // Ensure wrapper has execute permission (Xcode may strip +x on copy)
            if !FileManager.default.isExecutableFile(atPath: wrapperPath) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
            }
            logger.info("SSH remote mode: host=\(remote, privacy: .public) wrapper=\(wrapperPath, privacy: .public)")
        } else {
            // Local session: clear any ssh-claude-wrapper.sh left in the shared
            // settings file by pre-env-var Canopy builds, so the CLI spawns
            // directly. User-configured custom wrappers are preserved.
            CanopySettings.shared.clearStaleSSHWrapper()
        }

        // Custom API Provider: inject env vars before CLI starts.
        // These are read by the Claude CLI directly (ANTHROPIC_BASE_URL,
        // ANTHROPIC_AUTH_TOKEN, etc.) and map Anthropic model aliases to
        // third-party model ids.
        if let api = customApi, api.isEnabled {
            env["ANTHROPIC_BASE_URL"] = api.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = api.authToken.isEmpty ? "" : api.authToken
            // Remove inherited Anthropic key so it never leaks to a custom API endpoint
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            if !api.opusModel.isEmpty { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = api.opusModel }
            if !api.sonnetModel.isEmpty { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = api.sonnetModel }
            if !api.haikuModel.isEmpty { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = api.haikuModel }
            if !api.subagentModel.isEmpty { env["CLAUDE_CODE_SUBAGENT_MODEL"] = api.subagentModel }
            logger.info("Custom API: baseURL=\(api.baseURL, privacy: .private) opus=\(api.opusModel, privacy: .public) sonnet=\(api.sonnetModel, privacy: .public) haiku=\(api.haikuModel, privacy: .public) subagent=\(api.subagentModel, privacy: .public)")
        }

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

        // Read stdout — NDJSON from shim
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // Only disable on true EOF (process exited). Spurious empty reads
                // from a still-running process would permanently kill the handler.
                if self?.process?.isRunning != true {
                    handle.readabilityHandler = nil
                }
                return
            }
            self?.handleStdoutData(data)
        }

        // Read stderr — shim logs + CLI exit detection
        // Use nonisolated(unsafe) to satisfy Sendable requirements — the closure
        // only dispatches to main thread, never accesses self directly.
        nonisolated(unsafe) let weakSelf = self
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                for line in str.split(separator: "\n") {
                    logger.info("[shim] \(line, privacy: .public)")
                    // Detect CLI subprocess exit from extension error log
                    if line.contains("process exited with code") || line.contains("process terminated by signal") {
                        let lineStr = String(line)
                        DispatchQueue.main.async {
                            weakSelf.handleCLISubprocessExit(lineStr)
                        }
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] process in
            logger.info("Shim exited with status \(process.terminationStatus)")
            let pid = process.processIdentifier
            // Best-effort descendant cleanup — some may already be reparented to launchd.
            // Only needed for unexpected exits (stop() collects them before terminating).
            let orphans = Self.collectDescendants(of: pid)
            if !orphans.isEmpty {
                logger.info("Found \(orphans.count) orphan descendants after shim exit: \(orphans)")
                Self.killProcessTree(orphans)
            }
            DispatchQueue.main.async {
                self?.handleProcessExit(status: process.terminationStatus, pid: pid)
            }
        }

        do {
            try proc.run()
            logger.info("Shim started: PID \(proc.processIdentifier), node=\(nodeInfo.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to start shim: \(error.localizedDescription, privacy: .public)")
            showErrorInWebView("Failed to start Node.js: \(error.localizedDescription)")
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            return false
        }
    }

    func stop() {
        isIntentionalStop = true
        guard let proc = process, proc.isRunning else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()

        // Collect entire process tree BEFORE terminating parent (pgrep -P fails after parent exits)
        descendantPids = Self.collectDescendants(of: proc.processIdentifier)
        proc.terminate()

        // Kill all descendants: SIGTERM first, SIGKILL after brief wait
        Self.killProcessTree(descendantPids)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard var dict = message.body as? [String: Any] else { return }

        // Webview → host responses to permission requests close out the
        // `isAsking` flag on the bound OpenSession.
        trackPermissionResponse(dict)

        // Override permission mode in launch_claude from Canopy app settings
        if dict["type"] as? String == "launch_claude" {
            dict["permissionMode"] = permissionMode.rawValue

            let channelId = dict["channelId"] as? String ?? ""
            self.channelId = channelId.isEmpty ? nil : channelId
            let statusMsg: [String: Any] = [
                "type": "from-extension",
                "message": [
                    "type": "io_message",
                    "channelId": channelId,
                    "message": [
                        "type": "system",
                        "subtype": "status",
                        "permissionMode": permissionMode.rawValue,
                    ] as [String: Any],
                    "done": false,
                ] as [String: Any],
            ]
            sendToWebView(statusMsg)


            // Request initial rate limit data after a short delay (extension needs time to activate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.requestUsageUpdate()
            }
        }

        // Backstop: any webview→host message scoped to a running Claude
        // session (io_message, request, interrupt_claude, etc.) carries
        // channelId on the top-level dict. Channel-agnostic messages (init,
        // get_claude_state, get_asset_uris, list_sessions) don't, and the
        // !cid.isEmpty guard correctly skips them. If `launch_claude` failed
        // to set channelId for any reason, the next channel-scoped message
        // recovers it; without this, `requestSessionTitle`'s nil-guard would
        // silently disable title generation for the session's whole lifetime.
        // First non-empty channelId wins; once set, only the launch_claude
        // handler above is allowed to replace it.
        if self.channelId == nil,
           let cid = dict["channelId"] as? String, !cid.isEmpty
        {
            let msgType = dict["type"] as? String ?? "?"
            logger.info(
                "channelId recovered via backstop from \(msgType, privacy: .public) message"
            )
            self.channelId = cid
        }

        // Start spinner when user sends a message and request title generation
        if dict["type"] as? String == "io_message",
           let ioMsg = dict["message"] as? [String: Any],
           ioMsg["type"] as? String == "user"
        {
            isWorking = true

            // Capture user message text for fallback titles.
            if let userMsg = ioMsg["message"] as? [String: Any] {
                if let content = userMsg["content"] as? [[String: Any]] {
                    let extracted = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !extracted.isEmpty { lastUserMessageText = extracted }
                } else if let text = userMsg["content"] as? String, !text.isEmpty {
                    lastUserMessageText = text
                }
            }

            // Request AI title every `titleRefreshInterval` user messages.
            userMessagesSinceLastTitle += 1
            if userMessagesSinceLastTitle >= titleRefreshInterval,
               !titleRequestInFlight,
               let text = lastUserMessageText
            {
                requestSessionTitle(description: text)
            }
        }

        // Intercept requests from webview
        if let request = dict["request"] as? [String: Any],
           let reqType = request["type"] as? String
        {
            // Handle open_file: read file and show in ContentViewer directly.
            // open_content: show provided content in ContentViewer.
            if reqType == "open_file" {
                handleOpenFile(request, requestId: dict["requestId"] as? String)
                return
            }
            if reqType == "open_content" {
                handleOpenContent(request, requestId: dict["requestId"] as? String)
                return
            }

            if reqType == "rename_tab" || reqType == "update_session_state" {
                // Track session ID for title persistence.
                if let sid = request["sessionId"] as? String, UUID(uuidString: sid) != nil {
                    activeSessionId = sid
                    // Save any title that was generated before we had a session ID.
                    if let pending = pendingGeneratedTitle {
                        SessionTitleStore.save(title: pending, forSessionId: sid)
                        pendingGeneratedTitle = nil
                    }
                }
                if let title = request["title"] as? String, !title.isEmpty {
                    // Once an AI title (or fallback) has been applied, block
                    // raw webview titles — the extension keeps re-sending its
                    // stale internal title and would otherwise overwrite.
                    if !hasGeneratedTitle {
                        updateWindowTitle(Self.truncatedTitle(title))
                    }
                }
            }
        }

        sendToShim(["type": "webview_message", "message": dict])
    }

    // MARK: - WebView Ready

    func webViewDidFinishLoad() {
        sendToShim(["type": "webview_ready"])

        // Force webview permission mode UI after a short delay
        // (webview needs time to process init_response first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncPermissionModeToWebView()
        }
    }

    private func syncPermissionModeToWebView() {
        // NOTE: Do NOT send synthetic update_state here — it would reset authStatus to null
        // because update_state handler does: this.authStatus.value = state.authStatus ?? null.
        // Permission mode sync is handled via synthetic system/status io_message in
        // the launch_claude intercept.
        logger.info("Permission mode will sync via system/status on launch_claude")
    }

    // MARK: - Claude Settings

    /// Write or remove multiple keys in ~/.claude/settings.json atomically (single read-modify-write).
    private static func applyClaudeSettings(_ pairs: [(key: String, value: String?)]) {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let path = claudeDir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        var dict: [String: Any] = (try? Data(contentsOf: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (key, value) in pairs {
            if let value {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
        }
        let desc = pairs.map { "\($0.key)=\($0.value ?? "nil")" }.joined(separator: ", ")
        logger.info("Applied ~/.claude/settings.json: \(desc, privacy: .public)")
    }

    // MARK: - Shim Path Discovery

    nonisolated static func findShimPath() -> String? {
        // 1. Bundle resources (production — after Task 13 bundles vscode-shim)
        if let bundled = Bundle.main.path(forResource: "index", ofType: "js", inDirectory: "vscode-shim") {
            return bundled
        }

        // 2. Development fallback: navigate from this source file to Resources/vscode-shim/
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()   // Sources/Canopy/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // project root
        let devPath = projectRoot.appendingPathComponent("Resources/vscode-shim/index.js").path
        if FileManager.default.fileExists(atPath: devPath) {
            logger.info("Using development shim: \(devPath, privacy: .public)")
            return devPath
        }

        return nil
    }

    private static func findWrapperPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "ssh-claude-wrapper", ofType: "sh") {
            return bundled
        }
        // Development fallback
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = projectRoot.appendingPathComponent("Resources/ssh-claude-wrapper.sh").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    // MARK: - stdout NDJSON Parsing

    /// Called from the stdout readabilityHandler thread. Accumulates data and
    /// extracts complete NDJSON lines, dispatching parsed messages to the main thread.
    private func handleStdoutData(_ data: Data) {
        stdoutBuffer.append(data)

        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { continue }

            guard let jsonData = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = msg["type"] as? String
            else {
                let preview = String(data: lineData.prefix(200), encoding: .utf8) ?? "<binary>"
                logger.warning("Failed to parse shim NDJSON: \(preview, privacy: .public)")
                continue
            }

            let preview = String(line.prefix(120))
            logger.debug("[stdout] type=\(type, privacy: .public) preview=\(preview, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                self?.handleShimMessage(type: type, msg: msg)
            }
        }
    }

    // MARK: - Message Handling

    private func handleShimMessage(type: String, msg: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            logger.info("Shim ready, flushing \(self.pendingMessages.count) pending messages")
            for pending in pendingMessages {
                writeToStdin(pending)
            }
            pendingMessages.removeAll()

        case "webview_message":
            guard var innerMessage = msg["message"] as? [String: Any] else {
                logger.warning("webview_message with no 'message' field")
                return
            }
            let innerType = (innerMessage["type"] as? String) ?? "?"
            logger.debug("[stdout→webview] type=\(innerType, privacy: .public)")
            innerMessage = patchAuthIfNeeded(innerMessage)
            trackWorkingState(innerMessage)
            trackPermissionState(stdoutMessage: msg)
            extractStatusData(innerMessage)
            extractTitle(innerMessage)
            sendToWebView(innerMessage)

        case "show_document":
            if let content = msg["content"] as? String {
                let fileName = msg["fileName"] as? String ?? "output"
                ContentViewer.show(content: content, title: fileName, in: webView)
            }

        case "show_notification":
            handleNotification(msg)

        case "open_url":
            if let urlStr = msg["url"] as? String, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }

        case "open_terminal":
            openTerminal(msg)

        case "log":
            let level = msg["level"] as? String ?? "info"
            let message = msg["msg"] as? String ?? ""
            logger.info("[shim:\(level, privacy: .public)] \(message, privacy: .public)")

        case "error":
            let message = msg["message"] as? String ?? "Unknown error"
            let stack = msg["stack"] as? String
            logger.error("Shim error: \(message, privacy: .public)")
            if let stack { logger.error("Stack: \(stack, privacy: .public)") }

        default:
            logger.info("Unknown shim message: \(type, privacy: .public)")
        }
    }

    // MARK: - Host Events

    private func handleNotification(_ msg: [String: Any]) {
        guard let message = msg["message"] as? String,
              let requestId = msg["requestId"] as? String
        else {
            logger.warning("Malformed notification from shim: missing message or requestId")
            return
        }

        let severity = msg["severity"] as? String ?? "info"
        let buttons = msg["buttons"] as? [String] ?? []

        let alert = NSAlert()
        alert.messageText = message
        switch severity {
        case "error": alert.alertStyle = .critical
        case "warning": alert.alertStyle = .warning
        default: alert.alertStyle = .informational
        }
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let buttonValue: Any
        if buttonIndex < buttons.count {
            buttonValue = buttons[buttonIndex]
        } else {
            buttonValue = NSNull()
        }

        sendToShim([
            "type": "notification_response",
            "requestId": requestId,
            "buttonValue": buttonValue,
        ])
    }

    /// Handle open_file request from webview — show file in ContentViewer
    /// instead of forwarding to extension (which triggers file:// navigation → WebContent crash).
    private func handleOpenFile(_ request: [String: Any], requestId: String?) {
        let location = request["location"] as? [String: Any]

        // Extract file path: CC extension sends filePath at top level of the request,
        // location sub-dict may contain uri/line/col for positioning.
        var rawPath = request["filePath"] as? String
            ?? request["uri"] as? String
            ?? location?["uri"] as? String
            ?? location?["filePath"] as? String
            ?? location?["path"] as? String
            ?? location?["file"] as? String
        if let s = rawPath, s.hasPrefix("file://") {
            rawPath = URL(string: s)?.path ?? String(s.dropFirst(7))
        }

        if let filePath = rawPath {
            let url: URL
            if filePath.hasPrefix("/") {
                url = URL(fileURLWithPath: filePath)
            } else {
                url = workingDirectory.appendingPathComponent(filePath)
            }
            // Resolve symlinks and ensure the file is under the working directory (prevent path traversal)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let wdResolved = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(wdResolved.path + "/") || resolved.path == wdResolved.path else {
                logger.warning("handleOpenFile: path traversal blocked: \(resolved.path, privacy: .public)")
                if let requestId {
                    sendToWebView([
                        "type": "response",
                        "requestId": requestId,
                        "response": ["type": "open_file_response"] as [String: Any],
                    ] as [String: Any])
                }
                return
            }
            if FileManager.default.fileExists(atPath: resolved.path) {
                do {
                    let content = try String(contentsOf: resolved, encoding: .utf8)
                    let startLine = location?["startLine"] as? Int
                    let endLine = location?["endLine"] as? Int
                    logger.info("handleOpenFile: showing in ContentViewer: \(resolved.lastPathComponent, privacy: .public) line:\(startLine ?? 0, privacy: .public)-\(endLine ?? 0, privacy: .public)")
                    ContentViewer.show(content: content, title: resolved.lastPathComponent, in: webView, startLine: startLine, endLine: endLine)
                } catch {
                    logger.info("handleOpenFile: not UTF-8 text (\(error.localizedDescription, privacy: .public)), opening externally")
                    if !NSWorkspace.shared.open(resolved) {
                        logger.warning("handleOpenFile: NSWorkspace failed to open: \(resolved.path, privacy: .public)")
                    }
                }
            } else {
                logger.warning("handleOpenFile: file does not exist: \(resolved.path, privacy: .public)")
            }
        } else {
            logger.warning("handleOpenFile: no file path in location keys: \(location?.keys.sorted().description ?? "nil", privacy: .public)")
        }

        // Send response so the webview doesn't hang waiting (fire-and-forget if no requestId)
        if let requestId {
            sendToWebView([
                "type": "response",
                "requestId": requestId,
                "response": ["type": "open_file_response"] as [String: Any],
            ] as [String: Any])
        }
    }

    /// Handle open_content request — show provided content directly in ContentViewer.
    private func handleOpenContent(_ request: [String: Any], requestId: String?) {
        let content = request["content"] as? String ?? ""
        let fileName = request["fileName"] as? String ?? "untitled"
        ContentViewer.show(content: content, title: fileName, in: webView)

        if let requestId {
            sendToWebView([
                "type": "response",
                "requestId": requestId,
                "response": ["type": "open_content_response", "updatedContent": content] as [String: Any],
            ] as [String: Any])
        }
    }

    private func openTerminal(_ msg: [String: Any]) {
        let shellPath = msg["shellPath"] as? String
        let shellArgs = msg["shellArgs"] as? [String] ?? []
        let cwdPath = workingDirectory.path

        var parts = ["cd", shellQuote(cwdPath)]
        if let shellPath {
            parts.append("&&")
            parts.append(shellQuote(shellPath))
            for arg in shellArgs {
                parts.append(shellQuote(arg))
            }
        }
        let command = parts.joined(separator: " ")

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            logger.error("Failed to open terminal: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Auth State Cache

    /// Intercept messages to inject authStatus from Keychain and override permission/experiment settings.
    private func patchAuthIfNeeded(_ message: [String: Any]) -> [String: Any] {
        guard message["type"] as? String == "from-extension",
              var nested = message["message"] as? [String: Any]
        else { return message }

        // Patch update_state: override permission/experiment settings but do NOT inject authStatus.
        // The extension controls authStatus in update_state — injecting keychain auth here
        // would prevent /login and "Switch Account" from showing the login screen.
        if var request = nested["request"] as? [String: Any],
           request["type"] as? String == "update_state",
           var state = request["state"] as? [String: Any]
        {
            state["initialPermissionMode"] = permissionMode.rawValue
            state["allowDangerouslySkipPermissions"] = CanopySettings.shared.allowDangerouslySkipPermissions
            state["isOnboardingDismissed"] = true
            var gates = (state["experimentGates"] as? [String: Any]) ?? [:]
            gates["tengu_vscode_cc_auth"] = true
            state["experimentGates"] = gates
            request["state"] = state
            nested["request"] = request
            var patchedMessage = message
            patchedMessage["message"] = nested
            return patchedMessage
        }

        // Patch init_response: inject authStatus from Keychain if missing, permission mode, skipPermissions
        if var response = nested["response"] as? [String: Any],
           response["type"] as? String == "init_response",
           var state = response["state"] as? [String: Any]
        {
            logger.info("init_response state from extension: initialPermissionMode=\(state["initialPermissionMode"] as? String ?? "nil", privacy: .public) allowSkip=\(state["allowDangerouslySkipPermissions"] as? Bool ?? false, privacy: .public)")
            if state["authStatus"] == nil || state["authStatus"] is NSNull {
                if let keychainAuth = KeychainAuth.readAuthStatus() {
                    state["authStatus"] = keychainAuth
                    logger.info("Injected Keychain authStatus into init_response")
                }
            }
            state["initialPermissionMode"] = permissionMode.rawValue
            state["allowDangerouslySkipPermissions"] = CanopySettings.shared.allowDangerouslySkipPermissions
            state["isOnboardingDismissed"] = true
            var gates = (state["experimentGates"] as? [String: Any]) ?? [:]
            gates["tengu_vscode_cc_auth"] = true
            state["experimentGates"] = gates
            logger.info("Patched init_response: initialPermissionMode=\(self.permissionMode.rawValue, privacy: .public) allowSkip=true")
            response["state"] = state
            nested["response"] = response
            var patchedMessage = message
            patchedMessage["message"] = nested
            return patchedMessage
        }

        return message
    }

    // MARK: - Shim Communication

    /// Send a message to the shim via stdin. Buffers messages until the shim signals "ready",
    /// except for "webview_ready" which is sent immediately (the shim processes it pre-activation).
    private func sendToShim(_ msg: [String: Any]) {
        if !isReady && msg["type"] as? String != "webview_ready" {
            pendingMessages.append(msg)
            return
        }
        writeToStdin(msg)
    }

    private func writeToStdin(_ msg: [String: Any]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: msg)
                guard var str = String(data: data, encoding: .utf8) else {
                    logger.warning("writeToStdin: UTF-8 encode failed for message type: \(msg["type"] as? String ?? "?", privacy: .public)")
                    return
                }
                str += "\n"
                guard let writeData = str.data(using: .utf8) else { return }
                try self.stdinPipe?.fileHandleForWriting.write(contentsOf: writeData)
            } catch {
                logger.error("Failed to write to shim stdin: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendToWebView(_ message: Any) {
        guard let dict = message as? [String: Any] else {
            logger.warning("sendToWebView: message is not a dictionary: \(String(describing: type(of: message)), privacy: .public)")
            return
        }

        guard webView != nil else {
            logger.error("sendToWebView: webView is nil!")
            return
        }

        // Extension sends two formats:
        //   Unsolicited: {type:"from-extension", message:{...}} — already wrapped
        //   Responses:   {type:"response", requestId:"...", ...} — needs wrapping
        // VSCode internally wraps ALL extension→webview messages in {type:"from-extension"}.
        let jsPayload: String
        let payload: Any = dict["type"] as? String == "from-extension"
            ? dict
            : ["type": "from-extension", "message": dict] as [String: Any]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                logger.error("sendToWebView: UTF-8 encode failed")
                return
            }
            jsPayload = jsonStr
        } catch {
            logger.error("sendToWebView: JSON serialization failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let js = "window.postMessage(\(jsPayload),'*')"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                logger.error("sendToWebView JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Request rate limit data from extension (triggers /api/oauth/usage fetch).
    /// Throttled globally — only one tab sends the request per interval.
    private func requestUsageUpdate() {
        guard SharedRateLimitData.shared.shouldRequestUpdate() else { return }
        let requestId = "canopy-usage-\(UUID().uuidString.prefix(8))"
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "request",
                "requestId": requestId,
                "request": [
                    "type": "request_usage_update",
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    /// Send a synthetic generate_session_title request to the extension via shim.
    /// The extension forwards this to the CLI, which generates a short AI title.
    private func requestSessionTitle(description: String) {
        guard !description.isEmpty else { return }
        guard let channelId else {
            logger.warning("requestSessionTitle skipped: channelId still nil")
            return
        }
        titleRequestInFlight = true
        hasGeneratedTitle = false
        userMessagesSinceLastTitle = 0

        let requestId = "canopy-title-\(UUID().uuidString.prefix(8))"
        currentTitleRequestId = requestId
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "request",
                "requestId": requestId,
                "request": [
                    "type": "generate_session_title",
                    "channelId": channelId,
                    "description": "Generate a concise session title (max 40 chars, plain facts, no emoji, no roleplay): \(description)",
                    "persist": false,
                ] as [String: Any],
            ] as [String: Any],
        ])

        // Fallback: if the extension never responds (custom API providers
        // where generate_session_title may be slow or silently dropped),
        // use the most recent user message as the title.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.titleRequestInFlight else { return }
            self.titleRequestInFlight = false
            self.currentTitleRequestId = nil
            self.hasGeneratedTitle = true
            guard let fallback = self.lastUserMessageText, !fallback.isEmpty else { return }
            let truncated = Self.truncatedTitle(fallback)
            logger.info("Title fallback (AI generation timed out): \(truncated, privacy: .public)")
            self.updateWindowTitle(truncated)
            if let sid = self.activeSessionId ?? self.resumeSessionId {
                SessionTitleStore.save(title: truncated, forSessionId: sid)
            } else {
                self.pendingGeneratedTitle = truncated
            }
        }
    }

    /// Extract session title from extension responses flowing to webview.
    /// Responses are NOT wrapped in from-extension (only unsolicited messages are).
    /// Format: {type:"response", requestId:"...", response:{type:"generate_session_title_response", title:"..."}}
    /// Or wrapped: {type:"from-extension", message:{response:{...}}}
    private func extractTitle(_ message: [String: Any]) {
        // Try direct response (unwrapped format)
        if let response = message["response"] as? [String: Any] {
            applyTitleFromResponse(response, requestId: message["requestId"] as? String)
            return
        }

        // Try from-extension wrapped format
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           let response = nested["response"] as? [String: Any]
        {
            applyTitleFromResponse(response, requestId: nested["requestId"] as? String)
        }
    }

    private func applyTitleFromResponse(_ response: [String: Any], requestId: String? = nil) {
        guard let title = response["title"] as? String, !title.isEmpty else { return }
        let truncated = Self.truncatedTitle(title)
        let respType = response["type"] as? String ?? ""

        if respType == "generate_session_title_response" {
            // Reject stale responses that don't match the current request.
            if let requestId, let current = currentTitleRequestId, requestId != current {
                return
            }
            logger.info("Title generated: \(title, privacy: .public)")
            titleRequestInFlight = false
            currentTitleRequestId = nil
            hasGeneratedTitle = true
            updateWindowTitle(truncated)
            // Persist to our own store (like Sessylph's SessionTitleStore).
            if let sid = activeSessionId ?? resumeSessionId {
                SessionTitleStore.save(title: truncated, forSessionId: sid)
            } else {
                pendingGeneratedTitle = truncated
            }
        } else if respType == "rename_tab_response"
            || respType == "update_session_state_response"
        {
            // Always accept native title updates from the extension; they
            // reflect evolving conversation context. Periodic AI title
            // generation runs on its own cadence and overwrites when ready.
            logger.info("Title updated: \(title, privacy: .public)")
            updateWindowTitle(truncated)
        }
    }

    // MARK: - Window Title & Working State

    private static func truncatedTitle(_ title: String, maxLength: Int = 60) -> String {
        title.count > maxLength
            ? String(title.prefix(maxLength - 3)) + "..."
            : title
    }

    private func updateWindowTitle(_ title: String) {
        sessionTitle = title
        // Sidebar shell: SwiftUI's `.navigationTitle` on Detail and the
        // sidebar row both read `OpenSession.title`. Without this assignment
        // generated / renamed titles would only live in our private
        // `sessionTitle` and never reach the UI.
        boundSession?.title = title
    }

    /// Watch host→webview messages for `tool_permission_request` and pair
    /// them with their responses to mirror an `isAsking` flag onto the
    /// bound OpenSession. The sidebar lights up a raised-hand icon while
    /// at least one permission request is outstanding.
    private func trackPermissionState(stdoutMessage message: [String: Any]) {
        guard message["type"] as? String == "webview_message",
              let outer = message["message"] as? [String: Any]
        else { return }
        // Extension may wrap host→webview requests in `from-extension`.
        // Peel one layer if present.
        let inner: [String: Any]
        if outer["type"] as? String == "from-extension",
           let unwrapped = outer["message"] as? [String: Any] {
            inner = unwrapped
        } else {
            inner = outer
        }
        guard inner["type"] as? String == "request",
              let requestId = inner["requestId"] as? String,
              let request = inner["request"] as? [String: Any],
              let reqType = request["type"] as? String
        else { return }
        guard reqType == "tool_permission_request" else { return }
        pendingPermissionRequestIds.insert(requestId)
        refreshAskingState()
    }

    /// Webview→host responses arrive via `userContentController`. When one
    /// matches a tracked permission request id, clear it.
    private func trackPermissionResponse(_ webviewMessage: [String: Any]) {
        guard webviewMessage["type"] as? String == "response",
              let requestId = webviewMessage["requestId"] as? String
        else { return }
        guard pendingPermissionRequestIds.contains(requestId) else { return }
        pendingPermissionRequestIds.remove(requestId)
        refreshAskingState()
    }

    /// Recompute the asking flag from outstanding permission requests AND
    /// any pending AskUserQuestion tool call. Either condition flips the
    /// sidebar icon to "raised hand".
    ///
    /// AskUserQuestion is reflected as soon as we see the `tool_use` block,
    /// even while `isWorking` is still true — the CLI keeps streaming until
    /// the user picks an answer (no `result` fires meanwhile), so we'd
    /// otherwise stay stuck on the thinking flower forever.
    private func refreshAskingState() {
        let asking = !pendingPermissionRequestIds.isEmpty
            || lastAssistantHadAskUserQuestion
        boundSession?.isAsking = asking
    }

    /// Scan an io_message for `tool_use` blocks named `AskUserQuestion`,
    /// and also clear the AskUserQuestion flag when a new assistant turn
    /// begins (message_start stream_event). The latter handles the case
    /// where the user dismissed the answer panel via Escape and Claude
    /// started a new response without a fresh AskUserQuestion.
    private func detectAskUserQuestion(in ioMsg: [String: Any]) {
        let ioType = ioMsg["type"] as? String
        var found = false
        var newTurnStart = false
        if ioType == "assistant",
           let assistantMsg = ioMsg["message"] as? [String: Any],
           let content = assistantMsg["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   block["name"] as? String == "AskUserQuestion" {
                    found = true
                    break
                }
            }
        } else if ioType == "stream_event",
                  let event = ioMsg["event"] as? [String: Any] {
            let evType = event["type"] as? String
            if evType == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               block["name"] as? String == "AskUserQuestion" {
                found = true
            } else if evType == "message_start" {
                newTurnStart = true
            }
        }
        if newTurnStart && lastAssistantHadAskUserQuestion {
            // Stale flag from the previous turn — clear so the icon
            // returns to the thinking flower for THIS turn (and we'll
            // re-set it if the new turn also calls AskUserQuestion).
            lastAssistantHadAskUserQuestion = false
            refreshAskingState()
        }
        if found && !lastAssistantHadAskUserQuestion {
            lastAssistantHadAskUserQuestion = true
            // Immediately reflect — CLI won't emit `result` until the user
            // picks an answer, so waiting for that would never trigger the
            // raised-hand icon.
            refreshAskingState()
        }
    }

    /// Track CLI working state from io_message events flowing to webview.
    /// Message structure: {type:"from-extension", message:{type:"io_message", message:{type:"assistant"|"result"|...}}}
    private func trackWorkingState(_ message: [String: Any]) {
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any],
              nested["type"] as? String == "io_message",
              let ioMsg = nested["message"] as? [String: Any],
              let ioType = ioMsg["type"] as? String
        else { return }

        switch ioType {
        case "assistant", "stream_event":
            detectAskUserQuestion(in: ioMsg)
            isWorking = true
        case "result":
            if isWorking {
                isWorking = false
                postTaskCompletedNotification()
            }
            // After Claude finishes, the AskUserQuestion (if any) is now
            // visible in the webview waiting for the user's choice.
            refreshAskingState()
        default:
            break
        }
    }

    // MARK: - Status Bar Data Extraction

    /// Extract usage/cost/model data from CLI events for the native status bar.
    private func extractStatusData(_ message: [String: Any]) {
        guard let data = statusBarData else { return }
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any]
        else { return }

        // Intercept usage_update requests from extension → webview
        if let request = nested["request"] as? [String: Any],
           request["type"] as? String == "usage_update",
           let utilization = request["utilization"] as? [String: Any]
        {
            SharedRateLimitData.shared.update(from: utilization)
            return
        }

        // io_message events from CLI
        guard nested["type"] as? String == "io_message",
              let ioMsg = nested["message"] as? [String: Any],
              let ioType = ioMsg["type"] as? String
        else { return }

        switch ioType {
        case "stream_event":
            guard let event = ioMsg["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { return }

            if eventType == "message_start" {
                // Clear compact indicator on next API call (fresh context reported)
                data.clearCompactIndicator()
                requestUsageUpdate()
            }

            if eventType == "message_start",
               let msg = event["message"] as? [String: Any]
            {
                // Model name (raw ID; StatusBarView formats it for display)
                if let model = msg["model"] as? String {
                    data.model = model
                }
                // Context usage from message_start (current context at API call time)
                if let usage = msg["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    data.contextUsed = input + cacheCreate + cacheRead
                }
            }

        case "result":
            // Use the model with the largest contextWindow (main model); take its maxOutputTokens too
            if let modelUsage = ioMsg["modelUsage"] as? [String: Any] {
                var largestCW = 0
                var maxOutput = 0
                for (_, value) in modelUsage {
                    if let info = value as? [String: Any],
                       let cw = info["contextWindow"] as? Int,
                       cw > largestCW
                    {
                        largestCW = cw
                        maxOutput = info["maxOutputTokens"] as? Int ?? 0
                    }
                }
                if largestCW > 0 {
                    data.contextMax = largestCW
                    data.maxOutputTokens = maxOutput
                    UserDefaults.standard.set(largestCW, forKey: "statusBar.contextMax.\(workingDirectory.path)")
                    UserDefaults.standard.set(maxOutput, forKey: "statusBar.maxOutputTokens.\(workingDirectory.path)")
                }
            }
            // Refresh VCS branch (user may have switched branches during session)
            // Dispatch to background to avoid blocking main thread with subprocess calls
            let dir = workingDirectory
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let vcsInfo = Self.detectVCSInfo(at: dir) else { return }
                DispatchQueue.main.async {
                    self?.statusBarData?.vcsType = vcsInfo.type
                    self?.statusBarData?.gitBranch = vcsInfo.branch
                }
            }
            // Refresh rate limits after each turn
            requestUsageUpdate()

        case "user":
            data.messageCount += 1
            requestUsageUpdate()

        case "assistant":
            data.messageCount += 1
            requestUsageUpdate()
            // Update contextUsed to include output_tokens (matches CC popup: input + cache_creation + cache_read + output)
            let parentToolUseId = ioMsg["parent_tool_use_id"]
            if let msg = ioMsg["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any],
               parentToolUseId == nil || parentToolUseId is NSNull
            {
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                data.contextUsed = input + cacheCreate + cacheRead + output
            }

        case "compact_boundary":
            data.resetContext()

        default:
            break
        }
    }

    private func postTaskCompletedNotification() {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Canopy"
        content.body = sessionTitle.isEmpty ? "Task completed" : "\(sessionTitle) — completed"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("Notification error: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - CLI Subprocess Exit Detection

    /// Called when stderr contains evidence that the CLI subprocess died
    /// while the shim (Node.js) is still running.
    private func handleCLISubprocessExit(_ line: String) {
        guard !isIntentionalStop else { return }
        // Extract exit code from "process exited with code NNN"
        let exitCode: Int32
        if let range = line.range(of: "exited with code "),
           let code = Int32(line[range.upperBound...].prefix(while: \.isNumber)) {
            exitCode = code
        } else {
            exitCode = -1
        }
        logger.error("CLI subprocess died (code \(exitCode)), stopping shim")
        stop()
        delegate?.shimProcessDidCrash(self, status: exitCode)
    }

    // MARK: - Process Exit

    private func handleProcessExit(status: Int32, pid: pid_t) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if !descendantPids.isEmpty {
            Self.killProcessTree(descendantPids)
            descendantPids = []
        }

        guard !isIntentionalStop else { return }

        if remoteHost != nil, let sessionId = activeSessionId {
            logger.error("SSH disconnection detected (status \(status)), requesting reconnect for session \(sessionId, privacy: .public)")
            delegate?.shimProcessDidDisconnect(self, sessionId: sessionId)
        } else {
            logger.error("Shim exited unexpectedly (status \(status))")
            delegate?.shimProcessDidCrash(self, status: status)
        }
    }

    private func showErrorInWebView(_ message: String) {
        // Escape backslash FIRST, then single quotes
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.getElementById('claude-error');
            if (!el) { el = document.createElement('pre'); el.id = 'claude-error'; document.body.prepend(el); }
            el.style.cssText = 'display:block;position:fixed;top:0;left:0;right:0;z-index:9999;margin:0;padding:12px 16px;background:#fee2e2;color:#991b1b;font-size:13px;white-space:pre-wrap;font-family:-apple-system,sans-serif;';
            el.textContent = '\(escaped)';
        })()
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - VCS Branch Detection

    /// Detect VCS type and current branch/bookmark for status bar display.
    /// Checks for jj first (`.jj/` directory), falls back to git.
    private static func detectVCSInfo(at directory: URL) -> (type: StatusBarData.VCSType, branch: String)? {
        let fm = FileManager.default

        // Check for jj repo
        let jjDir = directory.appendingPathComponent(".jj")
        if fm.fileExists(atPath: jjDir.path), let jjPath = findExecutable("jj") {
            let status = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T",
                "if(empty, \"(empty)\", \"(modified)\")"], at: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 1. If @ has its own bookmarks, show them
            if let bookmarks = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T", "bookmarks"], at: directory) {
                let trimmed = bookmarks.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")
                if !trimmed.isEmpty {
                    let first = trimmed.components(separatedBy: " ").first ?? trimmed
                    return (.jj, "\(first) \(status)".trimmingCharacters(in: .whitespaces))
                }
            }

            // 2. No bookmarks on @ — check parent for context ("working on top of main")
            if let parentBookmarks = runCommand(jjPath, args: ["log", "-r", "@-", "--no-graph", "-T", "bookmarks"], at: directory) {
                let trimmed = parentBookmarks.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")
                if !trimmed.isEmpty {
                    let first = trimmed.components(separatedBy: " ").first ?? trimmed
                    return (.jj, "\(first) \(status)".trimmingCharacters(in: .whitespaces))
                }
            }

            // 3. Fallback: short change ID + status
            if let changeId = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T", "change_id.shortest(8)"], at: directory) {
                let trimmed = changeId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return (.jj, "\(trimmed) \(status)".trimmingCharacters(in: .whitespaces)) }
            }
            return (.jj, "")
        }

        // Fall back to git
        if let branch = runCommand("/usr/bin/git", args: ["rev-parse", "--abbrev-ref", "HEAD"], at: directory) {
            let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (.git, trimmed) }
        }

        return nil
    }

    /// Find an executable by name, checking common locations that GUI apps miss from PATH.
    private static func findExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.cargo/bin",
            NSHomeDirectory() + "/.local/share/mise/shims",
        ]
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run a command and return stdout as String, or nil on failure.
    private static func runCommand(_ executable: String, args: [String], at directory: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = directory
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            logger.debug("runCommand failed: \(executable) \(args.joined(separator: " ")): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }

    // MARK: - Process Tree Cleanup

    /// Recursively collect all descendant PIDs of a given process.
    /// Must be called BEFORE terminating the parent — once the parent exits,
    /// children are reparented to PID 1 and pgrep -P no longer finds them.
    private static func collectDescendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let directChildren = pgrepChildren(of: pid)
        var all = directChildren
        for child in directChildren {
            all.append(contentsOf: collectDescendants(of: child))
        }
        return all
    }

    /// Run `pgrep -P <pid>` and return the list of child PIDs.
    private static func pgrepChildren(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.warning("pgrep -P \(pid) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Send SIGTERM to all PIDs, wait briefly, then SIGKILL any survivors.
    private static func killProcessTree(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGTERM)
            logger.info("SIGTERM → PID \(pid)")
        }

        // Brief grace period for clean shutdown
        usleep(200_000) // 200ms

        for pid in pids {
            // Check if still alive (kill with signal 0 tests existence)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
                logger.info("SIGKILL → PID \(pid) (survived SIGTERM)")
            }
        }
    }
}
