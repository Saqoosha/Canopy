import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "ClaudeProcess")

/// Manages a Claude CLI process for a single conversation channel.
/// Spawns `claude -p --input-format stream-json --output-format stream-json --verbose`
/// and bridges NDJSON events to/from the webview via WebViewMessageHandler.
///
/// CLI `assistant` events are converted to Anthropic SSE streaming events (stream_event)
/// so the webview's React assembler builds the correct DOM structure (shared .message container
/// with .timelineMessage children, rather than separate elements).
final class ClaudeProcess: @unchecked Sendable {
    let channelId: String
    let sessionId: String

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private weak var messageHandler: WebViewMessageHandler?
    private var lineBuffer = Data()
    private let queue = DispatchQueue(label: "sh.saqoo.Hangar.ClaudeProcess")


    init(channelId: String, cwd: String, permissionMode: String, messageHandler: WebViewMessageHandler) {
        self.channelId = channelId
        self.sessionId = UUID().uuidString
        self.messageHandler = messageHandler

        process.executableURL = Self.claudePath
        process.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--permission-mode", permissionMode,
            "--session-id", sessionId,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.appendData(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                logger.error("[CLI stderr] \(str, privacy: .public)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            logger.info("[CLI] Process exited with status \(proc.terminationStatus, privacy: .public)")
            self.queue.async { self.flushBuffer() }
            DispatchQueue.main.async {
                self.messageHandler?.handleCLIProcessExited(channelId: self.channelId)
            }
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        try process.run()
        logger.info("[CLI] Started pid=\(self.process.processIdentifier) session=\(self.sessionId, privacy: .public)")
    }

    func sendUserMessage(_ text: String) {
        writeJSON([
            "type": "user",
            "message": [
                "role": "user",
                "content": text,
            ] as [String: Any],
        ])
    }

    func sendRawJSON(_ json: [String: Any]) {
        writeJSON(json)
    }

    func interrupt() {
        process.interrupt()
    }

    func terminate() {
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - NDJSON parsing

    private func appendData(_ data: Data) {
        lineBuffer.append(data)
        while let range = lineBuffer.range(of: Data([0x0A])) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex...range.lowerBound)
            if !lineData.isEmpty {
                processLine(lineData)
            }
        }
    }

    private func flushBuffer() {
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = Data()
        }
    }

    private func processLine(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            if let str = String(data: data, encoding: .utf8) {
                let preview = String(str.prefix(200))
                logger.warning("Failed to parse: \(preview, privacy: .public)")
            }
            return
        }

        let subtype = json["subtype"] as? String ?? ""
        logger.info("CLI event: type=\(type, privacy: .public) subtype=\(subtype, privacy: .public)")

        switch type {
        case "system":
            handleSystemEvent(json)
        case "stream_event":
            // Real Anthropic SSE streaming events — forward directly to webview!
            // Contains message_start, content_block_start, content_block_delta, etc.
            sendIOMessage(json, done: false)
        case "assistant":
            // Complete message (fallback when streaming events aren't available)
            sendIOMessage(json, done: false)
        case "user":
            handleUserEvent(json)
        case "result":
            handleResultEvent(json)
        case "rate_limit_event":
            sendIOMessage(json, done: false)
        default:
            logger.warning("Unknown CLI event: \(type, privacy: .public)")
        }
    }

    // MARK: - Event handling

    private func handleSystemEvent(_ json: [String: Any]) {
        let subtype = json["subtype"] as? String ?? "unknown"
        if subtype == "init" {
            let model = json["model"] as? String ?? "?"
            logger.info("[CLI] Init: model=\(model, privacy: .public)")
        }
    }

    private func handleUserEvent(_ json: [String: Any]) {
        logger.info("User event (tool result)")
        sendIOMessage(json, done: false)
    }

    private func handleResultEvent(_ json: [String: Any]) {
        sendIOMessage(json, done: true)
    }

    private func sendIOMessage(_ message: [String: Any], done: Bool) {
        let ioMessage: [String: Any] = [
            "type": "io_message",
            "channelId": channelId,
            "message": message,
            "done": done,
        ]
        let wrapped: [String: Any] = [
            "type": "from-extension",
            "message": ioMessage,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: wrapped),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.messageHandler?.sendJSToWebview(jsonString)
        }
    }

    // MARK: - Write to CLI stdin

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var json = String(data: data, encoding: .utf8)
        else { return }
        let preview = String(json.prefix(300))
        logger.info("Writing to CLI stdin: \(preview, privacy: .public)")
        json += "\n"
        queue.async { [weak self] in
            guard let self else { return }
            self.stdinPipe.fileHandleForWriting.write(json.data(using: .utf8)!)
        }
    }

    // MARK: - Claude binary path

    private static var claudePath: URL {
        let candidates = [
            "/Users/hiko/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/Users/hiko/.local/bin/claude")
    }
}
