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
    /// Whether we've already requested an AI-generated title for this session.
    private var titleRequested = false
    /// Whether an AI-generated title has been received (prevents raw title overwrite from webview).
    private var titleGenerated = false
    /// Session ID from webview's update_session_state, used to persist generated titles.
    private var activeSessionId: String?
    /// Generated title waiting to be saved (when activeSessionId arrives after the title response).
    private var pendingGeneratedTitle: String?

    private let writeQueue = DispatchQueue(label: "sh.saqoo.Canopy.shimWrite")

    let workingDirectory: URL
    var resumeSessionId: String?
    var model: String?
    var effortLevel: String?
    var permissionMode: PermissionMode
    var remoteHost: String?

    // MARK: - Window Title & Spinner
    private var sessionTitle: String = ""
    private var isWorking = false
    private var spinnerTimer: Timer?
    private var spinnerIndex = 0
    private static let spinnerFrames = ["·", "✻", "✽", "✶", "✳", "✢"]
    private static let idleIcon = "✳"
    private static let spinnerColor = NSColor(red: 0.851, green: 0.471, blue: 0.345, alpha: 1.0) // #D97858

    var statusBarData: StatusBarData?
    weak var delegate: ShimProcessDelegate?
    private var isIntentionalStop = false
    /// Whether the process wrapper has been cleared from settings after CLI spawned.
    private var wrapperCleared = false

    init(workingDirectory: URL, resumeSessionId: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, sessionTitle: String? = nil, statusBarData: StatusBarData? = nil, remoteHost: String? = nil) {
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
        self.model = model
        self.effortLevel = effortLevel
        self.permissionMode = permissionMode
        self.sessionTitle = sessionTitle ?? ""
        // When resuming with an AI-generated title, protect it from webview overwrite.
        if let st = sessionTitle, !st.isEmpty, resumeSessionId != nil {
            self.titleGenerated = true
        }
        self.statusBarData = statusBarData
        self.remoteHost = remoteHost
        super.init()
        // Set CLI version, VCS branch, initial message count, and remote host
        statusBarData?.cliVersion = CCExtension.extensionVersion() ?? ""
        statusBarData?.remoteHost = remoteHost
        let dir = workingDirectory
        let barData = statusBarData
        DispatchQueue.global(qos: .utility).async {
            guard let vcsInfo = Self.detectVCSInfo(at: dir) else { return }
            DispatchQueue.main.async {
                barData?.vcsType = vcsInfo.type
                barData?.gitBranch = vcsInfo.branch
            }
        }
        // Restore cached contextMax for immediate display on session resume
        let cachedMax = UserDefaults.standard.integer(forKey: "statusBar.contextMax.\(workingDirectory.path)")
        if cachedMax > 0 { statusBarData?.contextMax = cachedMax }
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

        // SSH remote: set env var and configure process wrapper
        if let remote = remoteHost {
            guard let wrapperPath = Self.findWrapperPath() else {
                logger.error("SSH remote: wrapper script not found in bundle")
                showErrorInWebView("SSH remote mode failed: wrapper script not found. Try reinstalling Canopy.")
                return false
            }
            env["CANOPY_SSH_HOST"] = remote
            env["CANOPY_SSH_CWD"] = workingDirectory.path
            // Ensure wrapper has execute permission (Xcode may strip +x on copy)
            if !FileManager.default.isExecutableFile(atPath: wrapperPath) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
            }
            CanopySettings.shared.setProcessWrapper(wrapperPath)
            logger.info("SSH remote mode: host=\(remote, privacy: .public) wrapper=\(wrapperPath, privacy: .public)")
        } else {
            // Local session: ensure no leftover wrapper from a previous SSH session
            CanopySettings.shared.setProcessWrapper(nil)
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
            refreshWindowTitle()
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
        stopSpinner()
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

        // Start spinner when user sends a message and request title generation
        if dict["type"] as? String == "io_message",
           let ioMsg = dict["message"] as? [String: Any],
           ioMsg["type"] as? String == "user"
        {
            if !isWorking {
                isWorking = true
                startSpinner()
            }
            // Request AI-generated short title for the first user message only.
            if !titleRequested, let userMsg = ioMsg["message"] as? [String: Any] {
                if let content = userMsg["content"] as? [[String: Any]] {
                    let text = content.compactMap { $0["text"] as? String }.joined()
                    requestSessionTitle(description: text)
                } else if let text = userMsg["content"] as? String {
                    requestSessionTitle(description: text)
                }
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
                    if !titleGenerated {
                        let truncated = title.count > 60
                            ? String(title.prefix(57)) + "..."
                            : title
                        updateWindowTitle(truncated)
                    } else {
                        // Don't overwrite generated title, but refresh in case window just became available.
                        refreshWindowTitle()
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

    private static func findShimPath() -> String? {
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
            // NOTE: Do NOT clear wrapper here — extension hasn't read it yet.
            // Wrapper is cleared on first CLI io_message (see wrapperCleared flag).

        case "webview_message":
            guard var innerMessage = msg["message"] as? [String: Any] else {
                logger.warning("webview_message with no 'message' field")
                return
            }
            let innerType = (innerMessage["type"] as? String) ?? "?"
            logger.debug("[stdout→webview] type=\(innerType, privacy: .public)")
            // Clear wrapper after CLI has spawned. Only trigger on io_message
            // (not init_response or update_state) — io_message proves the CLI
            // was spawned, meaning the extension already read the wrapper setting.
            if !wrapperCleared && remoteHost != nil && innerType == "from-extension" {
                if let nested = innerMessage["message"] as? [String: Any],
                   nested["type"] as? String == "io_message"
                {
                    wrapperCleared = true
                    CanopySettings.shared.setProcessWrapper(nil)
                    logger.info("Cleared process wrapper from settings (CLI is running)")
                }
            }
            innerMessage = patchAuthIfNeeded(innerMessage)
            trackWorkingState(innerMessage)
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
        guard !description.isEmpty, let channelId else { return }
        titleRequested = true
        let requestId = "canopy-title-\(UUID().uuidString.prefix(8))"
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "request",
                "requestId": requestId,
                "request": [
                    "type": "generate_session_title",
                    "channelId": channelId,
                    "description": description,
                    "persist": false,
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    /// Extract session title from extension responses flowing to webview.
    /// Responses are NOT wrapped in from-extension (only unsolicited messages are).
    /// Format: {type:"response", requestId:"...", response:{type:"generate_session_title_response", title:"..."}}
    /// Or wrapped: {type:"from-extension", message:{response:{...}}}
    private func extractTitle(_ message: [String: Any]) {
        // Try direct response (unwrapped format)
        if let response = message["response"] as? [String: Any] {
            applyTitleFromResponse(response)
            return
        }

        // Try from-extension wrapped format
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           let response = nested["response"] as? [String: Any]
        {
            applyTitleFromResponse(response)
        }
    }

    private func applyTitleFromResponse(_ response: [String: Any]) {
        guard let title = response["title"] as? String, !title.isEmpty else { return }
        let respType = response["type"] as? String ?? ""
        if respType == "generate_session_title_response" {
            logger.info("Title generated: \(title, privacy: .public)")
            titleGenerated = true
            updateWindowTitle(title)
            // Persist to our own store (like Sessylph's SessionTitleStore).
            if let sid = activeSessionId ?? resumeSessionId {
                SessionTitleStore.save(title: title, forSessionId: sid)
            } else {
                pendingGeneratedTitle = title
            }
        } else if respType == "rename_tab_response"
            || respType == "update_session_state_response"
        {
            if !titleGenerated {
                logger.info("Title updated: \(title, privacy: .public)")
                updateWindowTitle(title)
            }
        }
    }

    // MARK: - Window Title & Working State

    private func updateWindowTitle(_ title: String) {
        sessionTitle = title
        refreshWindowTitle()
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
            if !isWorking {
                isWorking = true
                startSpinner()
            }
        case "result":
            if isWorking {
                isWorking = false
                stopSpinner()
                postTaskCompletedNotification()
            }
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
                // Model name
                if let model = msg["model"] as? String {
                    data.model = Self.formatModelName(model)
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
            // Context window size from modelUsage — use largest (main model has the biggest window)
            if let modelUsage = ioMsg["modelUsage"] as? [String: Any] {
                var largestCW = 0
                for (_, value) in modelUsage {
                    if let info = value as? [String: Any],
                       let cw = info["contextWindow"] as? Int,
                       cw > largestCW
                    {
                        largestCW = cw
                    }
                }
                if largestCW > 0 {
                    data.contextMax = largestCW
                    UserDefaults.standard.set(largestCW, forKey: "statusBar.contextMax.\(workingDirectory.path)")
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

    /// Format model ID to display name: "claude-opus-4-6-20260328" → "Opus 4.6"
    private static func formatModelName(_ model: String) -> String {
        // Known patterns: claude-{name}-{major}-{minor}[-date]
        let stripped = model.replacingOccurrences(of: "claude-", with: "")
        let parts = stripped.components(separatedBy: "-")
        guard parts.count >= 3,
              let _ = Int(parts[1]),
              let _ = Int(parts[2])
        else { return model }
        let name = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        return "\(name) \(parts[1]).\(parts[2])"
    }

    private func refreshWindowTitle() {
        guard let window = webView?.window else { return }
        let dirName = workingDirectory.lastPathComponent
        let icon = isWorking ? Self.spinnerFrames[spinnerIndex] : Self.idleIcon
        let hostPrefix = remoteHost != nil ? "[\(remoteHost!)] " : ""
        let rest = sessionTitle.isEmpty ? dirName : "\(dirName) — \(sessionTitle)"
        let plainTitle = "\(icon) \(hostPrefix)\(rest)"
        window.title = plainTitle

        let attributed = NSMutableAttributedString()
        let iconAttrs: [NSAttributedString.Key: Any] = isWorking
            ? [.foregroundColor: Self.spinnerColor]
            : [.foregroundColor: NSColor.secondaryLabelColor]
        attributed.append(NSAttributedString(string: "\(icon) ", attributes: iconAttrs))
        if let remote = remoteHost {
            attributed.append(NSAttributedString(string: "[\(remote)] ", attributes: [.foregroundColor: NSColor.systemOrange]))
        }
        attributed.append(NSAttributedString(string: rest))
        window.tab.attributedTitle = attributed
    }

    private func startSpinner() {
        spinnerTimer?.invalidate()
        spinnerIndex = 0
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinnerIndex = (self.spinnerIndex + 1) % Self.spinnerFrames.count
            self.refreshWindowTitle()
        }
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinnerIndex = 0
        refreshWindowTitle()
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
