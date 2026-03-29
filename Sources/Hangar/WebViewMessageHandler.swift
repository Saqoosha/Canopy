import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "MessageHandler")

final class WebViewMessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    /// Active Claude CLI processes keyed by channelId
    private var channels: [String: ClaudeProcess] = [:]

    /// Pending control requests from CLI awaiting webview response.
    /// Key: webview requestId, Value: (channelId, CLI request_id, tool_use_id)
    private var pendingControlRequests: [String: (channelId: String, cliRequestId: String, toolUseId: String)] = [:]

    /// Cached auth status from `claude auth status`
    private var cachedAuth: [String: Any]?

    /// Working directory for Claude sessions
    let workingDirectory: URL

    /// Permission mode for CLI launches (updated by webview set_permission_mode)
    var permissionMode: PermissionMode = .acceptEdits

    /// Session ID to resume (nil = new session)
    var resumeSessionId: String?

    init(workingDirectory: URL, resumeSessionId: String? = nil, permissionMode: PermissionMode = .acceptEdits) {
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
        super.init()
        fetchAuthStatus()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any] else { return }
        handleMessage(dict)
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "request":
            handleRequest(message)
        case "response":
            handleResponse(message)
        case "launch_claude":
            handleLaunchClaude(message)
        case "io_message":
            handleIOMessage(message)
        case "interrupt_claude":
            handleInterrupt(message)
        case "close_channel":
            handleCloseChannel(message)
        default:
            logger.info("[Hangar] Unknown message type: \(type, privacy: .public)")
        }
    }

    // MARK: - Request/Response

    private func handleRequest(_ message: [String: Any]) {
        guard let requestId = message["requestId"] as? String,
              let request = message["request"] as? [String: Any],
              let requestType = request["type"] as? String
        else { return }

        logger.info("[Hangar] Request: \(requestType) (id: \(requestId, privacy: .public))")

        switch requestType {
        case "init":
            sendResponse(requestId: requestId, response: initResponse())
        case "get_claude_state":
            sendResponse(requestId: requestId, response: claudeStateResponse())
        case "get_asset_uris":
            sendResponse(requestId: requestId, response: assetUrisResponse())
        case "get_current_selection":
            sendResponse(requestId: requestId, response: [
                "type": "get_current_selection_response",
                "selection": NSNull(),
            ])
        case "list_sessions_request":
            let sessions = ClaudeSessionHistory.loadSessions(for: workingDirectory)
            let sessionDicts = sessions.map { session -> [String: Any] in
                [
                    "id": session.id,
                    "title": session.title,
                    "timestamp": Int(session.timestamp.timeIntervalSince1970 * 1000),
                    "projectPath": session.projectDirectory.path,
                ]
            }
            sendResponse(requestId: requestId, response: [
                "type": "list_sessions_response",
                "sessions": sessionDicts,
            ])
        case "get_session_request":
            handleGetSession(requestId: requestId, sessionId: request["sessionId"] as? String)
        case "request_usage_update":
            sendResponse(requestId: requestId, response: [
                "type": "usage_update",
                "usage": NSNull(),
            ])
        case "login":
            handleLogin(requestId: requestId)
        case "open_url":
            if let url = request["url"] as? String, let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
            sendResponse(requestId: requestId, response: ["type": "open_url_response"])
        case "open_config":
            sendResponse(requestId: requestId, response: ["type": "open_config_response"])
        case "exec":
            sendResponse(requestId: requestId, response: ["type": "exec_response"])
        case "open_help":
            if let url = URL(string: "https://docs.anthropic.com/en/docs/claude-code") {
                NSWorkspace.shared.open(url)
            }
            sendResponse(requestId: requestId, response: ["type": "open_help_response"])
        case "set_model":
            sendResponse(requestId: requestId, response: ["type": "set_model_response"])
        case "set_thinking_level":
            sendResponse(requestId: requestId, response: ["type": "set_thinking_level_response"])
        case "set_permission_mode":
            if let modeStr = request["mode"] as? String,
               let mode = PermissionMode(rawValue: modeStr)
            {
                permissionMode = mode
                logger.info("[Hangar] Permission mode set to: \(modeStr, privacy: .public)")
                // Restart active CLI processes with the new permission mode
                for (channelId, oldProcess) in channels {
                    clearPendingRequests(for: channelId)
                    let cwd = oldProcess.cwd
                    let sessionId = oldProcess.sessionId
                    oldProcess.terminate()
                    if let newProcess = ClaudeProcess(
                        channelId: channelId,
                        cwd: cwd,
                        permissionMode: modeStr,
                        resumeSessionId: sessionId,
                        messageHandler: self
                    ) {
                        channels[channelId] = newProcess
                        try? newProcess.start()
                        logger.info("[Hangar] Restarted CLI for channel \(channelId, privacy: .public) with mode \(modeStr, privacy: .public)")
                    }
                }
            } else {
                logger.warning("[Hangar] Invalid permission mode: \(String(describing: request["mode"]), privacy: .public)")
            }
            sendResponse(requestId: requestId, response: ["type": "set_permission_mode_response"])
        case "log_event":
            sendResponse(requestId: requestId, response: ["type": "log_event_response"])
        case "get_mcp_servers":
            sendResponse(requestId: requestId, response: [
                "type": "get_mcp_servers_response",
                "servers": [] as [Any],
            ])
        case "list_plugins":
            sendResponse(requestId: requestId, response: [
                "type": "list_plugins_response",
                "plugins": [] as [Any],
            ])
        case "generate_session_title":
            sendResponse(requestId: requestId, response: [
                "type": "generate_session_title_response",
                "title": "Chat",
            ])
        case "rename_session", "rename_tab", "update_session_state",
             "dismiss_terminal_banner", "dismiss_review_upsell_banner",
             "dismiss_onboarding", "apply_settings", "fork_conversation":
            // Acknowledge but no-op
            sendResponse(requestId: requestId, response: [
                "type": "\(requestType)_response",
            ])
        default:
            logger.info("[Hangar] Unhandled request: \(requestType, privacy: .public)")
            sendResponse(requestId: requestId, response: [
                "type": "error",
                "error": "Not implemented: \(requestType)",
            ])
        }
    }

    // MARK: - Response (from webview → host, e.g. permission decisions)

    private func handleResponse(_ message: [String: Any]) {
        guard let requestId = message["requestId"] as? String,
              let response = message["response"] as? [String: Any],
              let responseType = response["type"] as? String
        else {
            logger.warning("[Hangar] Malformed response from webview: missing requestId, response, or type")
            return
        }

        logger.info("[Hangar] Response: \(responseType) (id: \(requestId, privacy: .public))")

        switch responseType {
        case "tool_permission_response":
            handlePermissionResponse(requestId: requestId, response: response)
        default:
            logger.info("[Hangar] Unhandled response type: \(responseType, privacy: .public)")
        }
    }

    /// Handle the webview's permission decision and send control_response back to CLI.
    private func handlePermissionResponse(requestId: String, response: [String: Any]) {
        guard let pending = pendingControlRequests.removeValue(forKey: requestId) else {
            logger.warning("[Hangar] No pending control request for id: \(requestId, privacy: .public)")
            return
        }
        guard let process = channels[pending.channelId] else {
            logger.warning("[Hangar] No process for channel: \(pending.channelId, privacy: .public)")
            return
        }

        // Extract the result from webview response
        var result = response["result"] as? [String: Any] ?? [:]
        result["toolUseID"] = pending.toolUseId

        let controlResponse: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": pending.cliRequestId,
                "response": result,
            ] as [String: Any],
        ]

        let behavior = result["behavior"] as? String ?? "unknown"
        logger.info("[Hangar] Permission response: \(behavior) for \(pending.cliRequestId, privacy: .public)")

        process.sendControlResponse(controlResponse)
    }

    // MARK: - Control Request (from CLI → webview, e.g. permission prompts)

    /// Handle a control_request from the CLI process and forward to webview.
    func handleCLIControlRequest(channelId: String, json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
              let request = json["request"] as? [String: Any],
              let subtype = request["subtype"] as? String
        else {
            logger.warning("[Hangar] Invalid control_request: missing fields")
            // Try to send error response to prevent CLI hang
            if let reqId = json["request_id"] as? String,
               let process = channels[channelId]
            {
                process.sendControlResponse([
                    "type": "control_response",
                    "response": [
                        "subtype": "error",
                        "request_id": reqId,
                        "error": "Invalid control_request: missing fields",
                    ] as [String: Any],
                ])
            }
            return
        }

        switch subtype {
        case "can_use_tool":
            let toolName = request["tool_name"] as? String ?? ""
            let inputs = request["input"] ?? [String: Any]()
            let suggestions = request["permission_suggestions"]
            let toolUseId = request["tool_use_id"] as? String ?? ""

            // Store pending request for routing response back to CLI
            pendingControlRequests[requestId] = (channelId: channelId, cliRequestId: requestId, toolUseId: toolUseId)

            // Forward to webview as tool_permission_request
            let webviewRequest: [String: Any] = [
                "type": "from-extension",
                "message": [
                    "type": "request",
                    "channelId": channelId,
                    "requestId": requestId,
                    "request": [
                        "type": "tool_permission_request",
                        "toolName": toolName,
                        "inputs": inputs,
                        "suggestions": suggestions ?? NSNull(),
                    ] as [String: Any],
                ] as [String: Any],
            ]

            logger.info("[Hangar] Forwarding permission request: \(toolName) (id: \(requestId, privacy: .public))")
            sendToWebview(webviewRequest)

        default:
            logger.info("[Hangar] Unhandled control_request subtype: \(subtype, privacy: .public)")
            // Send error response back to CLI so it doesn't hang
            if let process = channels[channelId] {
                process.sendControlResponse([
                    "type": "control_response",
                    "response": [
                        "subtype": "error",
                        "request_id": requestId,
                        "error": "Unsupported control request: \(subtype)",
                    ] as [String: Any],
                ])
            }
        }
    }

    /// Handle a control_cancel_request from the CLI — dismiss the pending permission dialog.
    func handleCLIControlCancel(channelId: String, json: [String: Any]) {
        guard let requestId = json["request_id"] as? String else {
            logger.warning("[Hangar] control_cancel_request missing request_id")
            return
        }

        if pendingControlRequests.removeValue(forKey: requestId) != nil {
            // Tell webview to dismiss the permission dialog
            sendToWebview([
                "type": "from-extension",
                "message": [
                    "type": "cancel_request",
                    "targetRequestId": requestId,
                ] as [String: Any],
            ])
            logger.info("[Hangar] Cancelled permission request: \(requestId, privacy: .public)")
        }
    }

    /// Remove all pending control requests for a given channel.
    private func clearPendingRequests(for channelId: String) {
        let stale = pendingControlRequests.filter { $0.value.channelId == channelId }
        for (requestId, _) in stale {
            pendingControlRequests.removeValue(forKey: requestId)
        }
        if !stale.isEmpty {
            logger.info("[Hangar] Cleared \(stale.count, privacy: .public) pending control requests for channel \(channelId, privacy: .public)")
        }
    }

    // MARK: - Launch Claude

    private func handleLaunchClaude(_ message: [String: Any]) {
        let channelId = message["channelId"] as? String ?? UUID().uuidString
        let cwd = message["cwd"] as? String ?? workingDirectory.path
        let permissionModeStr = message["permissionMode"] as? String ?? self.permissionMode.rawValue
        // Check webview message first, then fall back to stored resume ID
        let sessionToResume = message["sessionId"] as? String ?? resumeSessionId

        logger.info("[Hangar] launch_claude: channel=\(channelId) cwd=\(cwd) mode=\(permissionModeStr, privacy: .public) resume=\(sessionToResume ?? "new", privacy: .public)")

        // Clean up existing process for this channel
        channels[channelId]?.terminate()

        // Clear resume ID after first use
        resumeSessionId = nil

        guard let process = ClaudeProcess(
            channelId: channelId,
            cwd: cwd,
            permissionMode: permissionModeStr,
            resumeSessionId: sessionToResume,
            messageHandler: self
        ) else {
            logger.error("Failed to create ClaudeProcess: CLI binary not found")
            sendToWebview([
                "type": "from-extension",
                "message": [
                    "type": "io_message",
                    "channelId": channelId,
                    "message": [
                        "type": "result",
                        "subtype": "error",
                        "is_error": true,
                        "error": "Claude CLI not found. Install Claude Code first.",
                    ] as [String: Any],
                    "done": true,
                ] as [String: Any],
            ])
            return
        }
        channels[channelId] = process

        do {
            try process.start()
        } catch {
            logger.error("Failed to start Claude process: \(error.localizedDescription, privacy: .public)")
            sendToWebview([
                "type": "from-extension",
                "message": [
                    "type": "io_message",
                    "channelId": channelId,
                    "message": [
                        "type": "result",
                        "subtype": "error",
                        "is_error": true,
                        "error": "Failed to start Claude: \(error.localizedDescription)",
                    ] as [String: Any],
                    "done": true,
                ] as [String: Any],
            ])
        }
    }

    // MARK: - IO Message (from webview → CLI)

    private func handleIOMessage(_ message: [String: Any]) {
        guard let channelId = message["channelId"] as? String,
              let ioMsg = message["message"] as? [String: Any]
        else { return }

        let msgType = ioMsg["type"] as? String ?? "unknown"
        logger.info("[Hangar] io_message from webview: channel=\(channelId, privacy: .public) type=\(msgType, privacy: .public)")

        guard let process = channels[channelId] else {
            logger.info("[Hangar] No process for channel \(channelId, privacy: .public)")
            return
        }

        // The webview sends user messages as:
        // { type: "user", message: { role: "user", content: [{type:"text", text:"..."}] }, ... }
        // CLI stream-json expects: { type: "user", message: { role: "user", content: "..." } }
        if msgType == "user",
           let innerMsg = ioMsg["message"] as? [String: Any]
        {
            // Extract plain text from content blocks
            var text = ""
            if let contentStr = innerMsg["content"] as? String {
                text = contentStr
            } else if let contentArr = innerMsg["content"] as? [[String: Any]] {
                text = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            logger.info("[Hangar] Sending to CLI: \(text, privacy: .public)")
            process.sendUserMessage(text)
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: ioMsg),
               let str = String(data: data, encoding: .utf8)
            {
                let preview = String(str.prefix(500))
                logger.info("[Hangar] unhandled io_message: \(preview, privacy: .public)")
            }
        }
    }

    // MARK: - Session Loading (get_session_request)

    /// Handle `get_session_request` from the webview — the proper protocol for session restore.
    /// The webview sets `isLoading=true`, sends this request, we return messages,
    /// and the webview calls `loadFromMessages` then sets `isLoading=false`.
    /// All heavy work runs on a background thread.
    private func handleGetSession(requestId: String, sessionId: String?) {
        guard let sessionId else {
            sendResponse(requestId: requestId, response: [
                "type": "get_session_response",
                "messages": [] as [Any],
                "sessionDiffs": [] as [Any],
            ])
            return
        }

        let cwd = workingDirectory.path

        DispatchQueue.global(qos: .userInitiated).async {
            let messages = Self.loadSessionMessages(sessionId: sessionId, cwd: cwd)
            // Serialize to JSON string (Sendable) on background thread
            guard let data = try? JSONSerialization.data(withJSONObject: messages),
                  let messagesJSON = String(data: data, encoding: .utf8)
            else {
                logger.error("[Hangar] Failed to serialize session messages")
                return
            }
            let count = messages.count
            DispatchQueue.main.async { [weak self] in
                // Re-parse on main thread to satisfy Sendable boundary
                guard let messagesData = messagesJSON.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: messagesData)
                else { return }
                self?.sendResponse(requestId: requestId, response: [
                    "type": "get_session_response",
                    "messages": parsed,
                    "sessionDiffs": [] as [Any],
                ])
                logger.info("[Hangar] get_session_response: \(count, privacy: .public) messages for \(sessionId, privacy: .public)")
            }
        }
    }

    /// Parse session JSONL file, walk the parentUuid chain from leaf,
    /// and return formatted messages matching the VSCode extension format:
    /// `{ type, uuid, session_id, message, parent_tool_use_id, timestamp }`
    private nonisolated static func loadSessionMessages(sessionId: String, cwd: String) -> [[String: Any]] {
        let encoded = ClaudeSessionHistory.encodePath(cwd)
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let sessionFile = claudeDir.appendingPathComponent("\(encoded)/\(sessionId).jsonl")

        guard let text = try? String(contentsOf: sessionFile, encoding: .utf8) else {
            logger.error("[Hangar] Failed to read session file: \(sessionFile.path, privacy: .public)")
            return []
        }

        // Parse messages into UUID-keyed map
        var messagesByUuid: [String: [String: Any]] = [:]
        var lastUuid: String?

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let uuid = json["uuid"] as? String
            else { continue }

            switch type {
            case "user", "assistant", "system", "attachment", "progress":
                messagesByUuid[uuid] = json
                if json["isSidechain"] as? Bool != true,
                   json["isMeta"] as? Bool != true,
                   json["teamName"] == nil,
                   (type == "user" || type == "assistant")
                {
                    lastUuid = uuid
                }
            default:
                break
            }
        }

        guard let leafUuid = lastUuid else { return [] }

        // Walk chain from leaf backwards
        var chain: [[String: Any]] = []
        var visited = Set<String>()
        var current: String? = leafUuid

        while let uuid = current, let msg = messagesByUuid[uuid] {
            if visited.contains(uuid) { break }
            visited.insert(uuid)

            let type = msg["type"] as? String
            let isSidechain = msg["isSidechain"] as? Bool == true
            let isMeta = msg["isMeta"] as? Bool == true
            let hasTeam = msg["teamName"] != nil

            if !isSidechain && !isMeta && !hasTeam {
                if type == "user" || type == "assistant" || type == "system" {
                    chain.append(msg)
                }
            }
            current = msg["parentUuid"] as? String
        }

        chain.reverse()

        // Filter and format matching VSCode extension's wN6() format
        return chain.compactMap { msg in
            let type = msg["type"] as? String
            guard type == "user" || type == "assistant" else { return nil }
            return [
                "type": type as Any,
                "uuid": msg["uuid"] as Any,
                "session_id": msg["sessionId"] as Any,
                "message": msg["message"] as Any,
                "parent_tool_use_id": NSNull(),
                "timestamp": msg["timestamp"] as Any,
            ] as [String: Any]
        }
    }

    // MARK: - Interrupt / Close

    private func handleInterrupt(_ message: [String: Any]) {
        guard let channelId = message["channelId"] as? String else {
            logger.warning("[Hangar] interrupt_claude missing channelId")
            return
        }
        logger.info("[Hangar] interrupt_claude: channel=\(channelId, privacy: .public)")
        channels[channelId]?.interrupt()
    }

    private func handleCloseChannel(_ message: [String: Any]) {
        guard let channelId = message["channelId"] as? String else {
            logger.warning("[Hangar] close_channel missing channelId")
            return
        }
        logger.info("[Hangar] close_channel: channel=\(channelId, privacy: .public)")
        channels[channelId]?.terminate()
        channels.removeValue(forKey: channelId)
        clearPendingRequests(for: channelId)
    }

    /// Terminate all running CLI processes (called during webview teardown).
    func terminateAll() {
        for (channelId, process) in channels {
            logger.info("[Hangar] Terminating process for channel \(channelId, privacy: .public)")
            process.terminate()
        }
        channels.removeAll()
    }

    /// Called by ClaudeProcess when the CLI process exits
    func handleCLIProcessExited(channelId: String) {
        logger.info("[Hangar] CLI process exited for channel \(channelId, privacy: .public)")
        channels.removeValue(forKey: channelId)
        clearPendingRequests(for: channelId)
    }

    // MARK: - Auth

    private func fetchAuthStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cliPath = CCExtension.cliBinaryPath() else {
                logger.error("Cannot fetch auth: CLI binary not found")
                return
            }
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = cliPath
            process.arguments = ["auth", "status"]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                // Read BEFORE waitUntilExit to avoid pipe deadlock
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if !stderrData.isEmpty, let errStr = String(data: stderrData, encoding: .utf8) {
                    logger.warning("Auth stderr: \(errStr, privacy: .public)")
                }
                guard !data.isEmpty else {
                    logger.error("Auth status returned empty data (exit code: \(process.terminationStatus, privacy: .public))")
                    return
                }
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        DispatchQueue.main.async {
                            self?.cachedAuth = json
                            let email = json["email"] as? String ?? "unknown"
                            let sub = json["subscriptionType"] as? String ?? "?"
                            logger.info("[Hangar] Auth: \(email, privacy: .public) (\(sub, privacy: .public))")
                        }
                    } else {
                        logger.error("Auth status returned non-dictionary JSON")
                    }
                } catch {
                    let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                    logger.error("Failed to parse auth JSON: \(error.localizedDescription, privacy: .public). Raw: \(preview, privacy: .public)")
                }
            } catch {
                logger.error("Failed to run auth status command: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleLogin(requestId: String) {
        // Open Claude login in browser
        if let url = URL(string: "https://claude.ai/login") {
            NSWorkspace.shared.open(url)
        }
        // Re-fetch auth after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.fetchAuthStatus()
        }
        sendResponse(requestId: requestId, response: ["type": "login_response"])
    }

    // MARK: - Protocol Responses

    private func initResponse() -> [String: Any] {
        let cwd = workingDirectory.path

        // Use real auth if available
        let authStatus: [String: Any]
        if let auth = cachedAuth, auth["loggedIn"] as? Bool == true {
            authStatus = [
                "authMethod": auth["authMethod"] ?? "claudeai",
                "email": auth["email"] ?? NSNull(),
                "subscriptionType": auth["subscriptionType"] ?? NSNull(),
            ]
        } else {
            authStatus = [
                "authMethod": "claudeai",
                "email": NSNull(),
                "subscriptionType": NSNull(),
            ]
        }

        return [
            "type": "init_response",
            "state": [
                "defaultCwd": cwd,
                "openNewInTab": false,
                "showTerminalBanner": false,
                "showReviewUpsellBanner": false,
                "isOnboardingEnabled": false,
                "isOnboardingDismissed": true,
                "authStatus": authStatus,
                "modelSetting": "default",
                "thinkingLevel": "default_on",
                "initialPermissionMode": permissionMode.rawValue,
                "allowDangerouslySkipPermissions": true,
                "platform": "macos",
                "speechToTextEnabled": false,
                "marketplaceType": "vscode",
                "useCtrlEnterToSend": false,
                "chromeMcpState": ["status": "disconnected"],
                "browserIntegrationSupported": false,
                "debuggerMcpState": ["status": "inactive"],
                "jupyterMcpState": ["status": "inactive"],
                "remoteControlState": ["status": "disconnected"],
                "spinnerVerbsConfig": NSNull(),
                "settings": NSNull(),
                "claudeSettings": NSNull(),
                "currentRepo": NSNull(),
                "experimentGates": [:] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func claudeStateResponse() -> [String: Any] {
        // Use real auth info for account
        let account: [String: Any]
        if let auth = cachedAuth, auth["loggedIn"] as? Bool == true {
            account = [
                "tokenSource": auth["authMethod"] ?? "claudeai",
                "subscriptionType": auth["subscriptionType"] ?? "pro",
            ]
        } else {
            account = [
                "tokenSource": "claudeai",
                "subscriptionType": NSNull(),
            ]
        }

        return [
            "type": "get_claude_state_response",
            "config": [
                "commands": [] as [Any],
                "models": [
                    [
                        "value": "claude-sonnet-4-6",
                        "displayName": "Claude Sonnet 4.6",
                        "supportsEffort": true,
                        "supportedEffortLevels": ["low", "medium", "high"],
                        "supportsAutoMode": true,
                        "description": "Fast and capable",
                    ],
                    [
                        "value": "claude-opus-4-6",
                        "displayName": "Claude Opus 4.6",
                        "supportsEffort": true,
                        "supportedEffortLevels": ["low", "medium", "high"],
                        "supportsAutoMode": true,
                        "description": "Most capable",
                    ],
                    [
                        "value": "claude-haiku-4-5-20251001",
                        "displayName": "Claude Haiku 4.5",
                        "supportsEffort": true,
                        "supportedEffortLevels": ["low", "medium", "high"],
                        "supportsAutoMode": false,
                        "description": "Fast and efficient",
                    ],
                ] as [[String: Any]],
                "agents": [] as [Any],
                "pid": ProcessInfo.processInfo.processIdentifier,
                "account": account,
                "fast_mode_state": "off",
            ] as [String: Any],
        ]
    }

    private func assetUrisResponse() -> [String: Any] {
        guard let extPath = Self.findCCExtensionPath() else {
            return ["type": "error", "error": "Extension not found"]
        }
        let res = extPath.appendingPathComponent("resources")
        return [
            "type": "asset_uris_response",
            "assetUris": [
                "clawd": [
                    "light": res.appendingPathComponent("clawd.svg").absoluteString,
                    "dark": res.appendingPathComponent("clawd.svg").absoluteString,
                ],
                "welcome-art": [
                    "light": res.appendingPathComponent("welcome-art-light.svg").absoluteString,
                    "dark": res.appendingPathComponent("welcome-art-dark.svg").absoluteString,
                ],
                "clawd-with-grad-cap": [
                    "light": res.appendingPathComponent("ClawdWithGradCap.png").absoluteString,
                    "dark": res.appendingPathComponent("ClawdWithGradCap.png").absoluteString,
                ],
                "onboarding-highlight-text": [
                    "light": res.appendingPathComponent("HighlightText.jpg").absoluteString,
                    "dark": res.appendingPathComponent("HighlightText.jpg").absoluteString,
                ],
                "onboarding-accept-mode": [
                    "light": res.appendingPathComponent("AcceptMode.jpg").absoluteString,
                    "dark": res.appendingPathComponent("AcceptMode.jpg").absoluteString,
                ],
                "onboarding-plan-mode": [
                    "light": res.appendingPathComponent("PlanMode.jpg").absoluteString,
                    "dark": res.appendingPathComponent("PlanMode.jpg").absoluteString,
                ],
            ] as [String: Any],
        ]
    }

    static func findCCExtensionPath() -> URL? {
        CCExtension.extensionPath()
    }

    // MARK: - Send to Webview

    private func sendResponse(requestId: String, response: [String: Any]) {
        let wrapper: [String: Any] = [
            "type": "from-extension",
            "message": [
                "type": "response",
                "requestId": requestId,
                "response": response,
            ],
        ]
        sendToWebview(wrapper)
    }

    func sendToWebview(_ message: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            guard let json = String(data: data, encoding: .utf8) else {
                logger.error("Failed to encode webview message as UTF-8")
                return
            }
            sendJSToWebview(json)
        } catch {
            logger.error("Failed to serialize webview message: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send pre-serialized JSON string to the webview. Accepts String (Sendable)
    /// so it can be called safely from background threads.
    func sendJSToWebview(_ json: String) {
        let js = "window.postMessage(\(json), '*');"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js) { result, error in
                if let error {
                    logger.error("JS eval error: \(error.localizedDescription, privacy: .public)")
                    let preview = String(json.prefix(200))
                    logger.error("Failed JSON: \(preview, privacy: .public)")
                }
            }
        }
    }
}
