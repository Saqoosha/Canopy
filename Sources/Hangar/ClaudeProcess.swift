import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "ClaudeProcess")

/// Manages a Claude CLI process for a single conversation channel.
/// All mutable state is accessed through `queue` (serial DispatchQueue) for thread safety.
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

    init?(channelId: String, cwd: String, permissionMode: String, messageHandler: WebViewMessageHandler) {
        guard let cliPath = CCExtension.cliBinaryPath() else {
            logger.error("Cannot create ClaudeProcess: CLI binary not found")
            return nil
        }

        self.channelId = channelId
        self.sessionId = UUID().uuidString
        self.messageHandler = messageHandler

        process.executableURL = cliPath
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
            if data.isEmpty {
                // EOF — clean up handler to avoid repeated empty reads
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.appendData(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                logger.error("[CLI stderr] \(str, privacy: .public)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            logger.info("[CLI] Process exited with status \(proc.terminationStatus, privacy: .public)")
            // Flush remaining buffer FIRST, then notify handler
            self.queue.async {
                self.flushBuffer()
                DispatchQueue.main.async {
                    self.messageHandler?.handleCLIProcessExited(channelId: self.channelId)
                }
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

    /// Interrupt the CLI process. Thread-safe via queue.
    func interrupt() {
        queue.async { [weak self] in
            self?.process.interrupt()
        }
    }

    /// Terminate the CLI process. Thread-safe via queue.
    func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.stdinPipe.fileHandleForWriting.closeFile()
            if self.process.isRunning {
                self.process.terminate()
            }
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
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let json = parsed as? [String: Any] else {
                logger.warning("CLI output is valid JSON but not a dictionary: \(String(describing: Swift.type(of: parsed)), privacy: .public)")
                return
            }
            guard let type = json["type"] as? String else {
                logger.warning("CLI JSON missing 'type' key")
                return
            }

            switch type {
            case "system":
                handleSystemEvent(json)
            case "stream_event":
                sendIOMessage(json, done: false)
            case "assistant":
                sendIOMessage(json, done: false)
            case "user":
                logger.info("User event (tool result)")
                sendIOMessage(json, done: false)
            case "result":
                sendIOMessage(json, done: true)
            case "rate_limit_event":
                sendIOMessage(json, done: false)
            default:
                logger.warning("Unknown CLI event: \(type, privacy: .public)")
            }
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            logger.warning("Failed to parse CLI NDJSON: \(error.localizedDescription, privacy: .public). Raw: \(preview, privacy: .public)")
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
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: wrapped)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                logger.error("Failed to encode JSON data as UTF-8 for channel \(self.channelId, privacy: .public)")
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.messageHandler?.sendJSToWebview(jsonString)
            }
        } catch {
            logger.error("Failed to serialize IO message: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Write to CLI stdin

    private func writeJSON(_ obj: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard var json = String(data: data, encoding: .utf8) else {
                logger.error("Failed to encode JSON to UTF-8 string")
                return
            }
            let preview = String(json.prefix(300))
            logger.info("Writing to CLI stdin: \(preview, privacy: .public)")
            json += "\n"
            queue.async { [weak self] in
                guard let self, self.process.isRunning else {
                    logger.warning("Attempted to write to stdin of terminated process")
                    return
                }
                guard let data = json.data(using: .utf8) else { return }
                self.stdinPipe.fileHandleForWriting.write(data)
            }
        } catch {
            logger.error("Failed to serialize stdin JSON: \(error.localizedDescription, privacy: .public)")
        }
    }
}
