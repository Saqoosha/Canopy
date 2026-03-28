import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "MessageHandler")

final class WebViewMessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    /// Active Claude CLI processes keyed by channelId
    private var channels: [String: ClaudeProcess] = [:]

    /// Cached auth status from `claude auth status`
    private var cachedAuth: [String: Any]?

    override init() {
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
            sendResponse(requestId: requestId, response: [
                "type": "list_sessions_response",
                "sessions": [] as [Any],
            ])
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

    // MARK: - Launch Claude

    private func handleLaunchClaude(_ message: [String: Any]) {
        let channelId = message["channelId"] as? String ?? UUID().uuidString
        let cwd = message["cwd"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        let permissionMode = message["permissionMode"] as? String ?? "default"

        logger.info("[Hangar] launch_claude: channel=\(channelId) cwd=\(cwd) mode=\(permissionMode, privacy: .public)")

        // Clean up existing process for this channel
        channels[channelId]?.terminate()

        let process = ClaudeProcess(
            channelId: channelId,
            cwd: cwd,
            permissionMode: permissionMode,
            messageHandler: self
        )
        channels[channelId] = process

        do {
            try process.start()
        } catch {
            logger.info("[Hangar] Failed to start Claude process: \(error, privacy: .public)")
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

    // MARK: - Interrupt / Close

    private func handleInterrupt(_ message: [String: Any]) {
        guard let channelId = message["channelId"] as? String else { return }
        logger.info("[Hangar] interrupt_claude: channel=\(channelId, privacy: .public)")
        channels[channelId]?.interrupt()
    }

    private func handleCloseChannel(_ message: [String: Any]) {
        guard let channelId = message["channelId"] as? String else { return }
        logger.info("[Hangar] close_channel: channel=\(channelId, privacy: .public)")
        channels[channelId]?.terminate()
        channels.removeValue(forKey: channelId)
    }

    /// Called by ClaudeProcess when the CLI process exits
    func handleCLIProcessExited(channelId: String) {
        logger.info("[Hangar] CLI process exited for channel \(channelId, privacy: .public)")
        channels.removeValue(forKey: channelId)
    }

    // MARK: - Auth

    private func fetchAuthStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/Users/hiko/.local/bin/claude")
            process.arguments = ["auth", "status"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        self?.cachedAuth = json
                        let email = json["email"] as? String ?? "unknown"
                        let sub = json["subscriptionType"] as? String ?? "?"
                        logger.info("[Hangar] Auth: \(email) (\(sub, privacy: .public))")
                    }
                }
            } catch {
                logger.info("[Hangar] Failed to fetch auth status: \(error, privacy: .public)")
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
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path

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
                "initialPermissionMode": "default",
                "allowDangerouslySkipPermissions": false,
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
                "subscriptionType": "pro",
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
        let extensionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: extensionsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("anthropic.claude-code-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
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
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        sendJSToWebview(json)
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
