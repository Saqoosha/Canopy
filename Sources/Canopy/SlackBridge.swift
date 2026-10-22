import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "SlackBridge")

/// The daemon's link to the Saqoolaude Worker. Questions asked in a bound Slack
/// thread arrive as `ask`; each goes into its session through the same queue as
/// `send_message` with `slackAsker`, and the turn's last reply goes back as
/// `answer`. Why, and the wire: docs/superpowers/specs/2026-10-22-slack-thread-binding-design.md.
///
/// The daemon dials out, so nothing on this Mac listens for the Worker.
@MainActor
final class SlackBridge {
    static private(set) var current: SlackBridge?

    static let endpoint = URL(string: "wss://saqoolaude.whatever-co.workers.dev/canopy/connect")!
    /// Prints `{"Authorization":"Bearer …"}`. The saqoolaude MCP registration runs the same
    /// helper, so the key stays in 1Password and this process never stores it.
    static let headersHelper = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/scripts/saqoolaude-mcp-headers.sh")
    /// A question still unanswered after this is answered as timed out.
    static let answerTimeout: TimeInterval = 30 * 60
    static let requestTimeout: Duration = .seconds(15)
    private static let maxBackoff: TimeInterval = 60

    private let store: SessionStore
    private var task: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 2
    private var pingTimer: Timer?
    private var waiters: [String: CheckedContinuation<Result<[String: Any], ControlProtocol.ControlError>, Never>] = [:]
    private var stopped = false

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        Self.current = self
        connect()
    }

    func stop() {
        stopped = true
        if Self.current === self { Self.current = nil }
        dropConnection()
        logger.notice("Slack bridge stopped")
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.headersHelper.path) else {
            logger.notice("no saqoolaude headers helper; the Slack bridge stays off")
            return
        }
        Task {
            let authorization = await Self.authorizationHeader()
            guard !stopped else { return }
            guard let authorization else {
                logger.error("the saqoolaude headers helper gave no Authorization header")
                scheduleReconnect()
                return
            }
            var request = URLRequest(url: Self.endpoint)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            logger.notice("connecting to the Saqoolaude Worker")
            startPing(task)
            receive(task)
        }
    }

    /// Runs the helper off the main thread. Its 1Password mount blocks while the app is locked,
    /// so a run that has not finished in 10 s is ended. The output is parsed here and never logged.
    private nonisolated static func authorizationHeader() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [headersHelper.path]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let headers = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
                continuation.resume(returning: process.terminationStatus == 0 ? headers?["Authorization"] : nil)
            }
        }
    }

    /// The async `receive` resumes on the main actor, so no completion closure runs off main
    /// (a closure literal written here would be `@MainActor` and abort there).
    private func receive(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    guard let self, self.task === task else { return }
                    logger.notice("Worker connection ended: \(error.localizedDescription, privacy: .public)")
                    self.dropConnection()
                    self.scheduleReconnect()
                    return
                }
                guard let self, self.task === task else { return }
                self.backoff = 2
                if case .string(let text) = message { self.handle(text) }
            }
        }
    }

    /// Cloudflare drops an idle WebSocket; a ping every 30 s keeps it, and a failed one ends it.
    private func startPing(_ task: URLSessionWebSocketTask) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Self.ping(task) }
    }

    /// Nonisolated: the pong handler runs on URLSession's queue.
    private nonisolated static func ping(_ task: URLSessionWebSocketTask) {
        task.sendPing { error in
            guard error != nil else { return }
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func dropConnection() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        for (_, waiter) in waiters { waiter.resume(returning: .failure(ControlProtocol.ControlError("the Slack bridge disconnected"))) }
        waiters.removeAll()
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.task == nil else { return }
                self.connect()
            }
        }
    }

    private func send(_ message: [String: Any]) -> Bool {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return false }
        Task {
            do { try await task.send(.string(text)) } catch {
                logger.error("send to the Worker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    // MARK: - Requests from this Mac (bind, unbind, list)

    /// One request to the Worker and its one reply (`bound`, `unbound`, `bindings` or `error`).
    func request(_ type: String, _ params: [String: Any]) async -> Result<[String: Any], ControlProtocol.ControlError> {
        let requestId = UUID().uuidString.lowercased()
        var message = params
        message["type"] = type
        message["requestId"] = requestId
        guard send(message) else { return .failure(ControlProtocol.ControlError("not connected to the Saqoolaude Worker")) }
        return await withCheckedContinuation { continuation in
            waiters[requestId] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.requestTimeout)
                self?.waiters.removeValue(forKey: requestId)?
                    .resume(returning: .failure(ControlProtocol.ControlError("the Saqoolaude Worker did not answer")))
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else {
            logger.error("unreadable frame from the Worker")
            return
        }
        if type == "ask" {
            handleAsk(message)
            return
        }
        guard let requestId = message["requestId"] as? String, let waiter = waiters.removeValue(forKey: requestId) else {
            logger.notice("Worker frame \(type, privacy: .public) with no waiting request")
            return
        }
        if type == "error" {
            waiter.resume(returning: .failure(ControlProtocol.ControlError(message["error"] as? String ?? "the Worker refused")))
        } else {
            waiter.resume(returning: .success(message))
        }
    }

    // MARK: - Questions from Slack

    private func handleAsk(_ message: [String: Any]) {
        guard let askId = message["askId"] as? String,
              let sessionKey = message["sessionKey"] as? String,
              let asker = message["asker"] as? String,
              let text = message["text"] as? String else {
            logger.error("ask frame missing a field")
            return
        }
        guard let session = store.openSession(for: [.key(sessionKey)]), let shim = session.shim else {
            answer(askId, refusal: "the session is not open on Saqoosha's Mac")
            return
        }
        if let why = ControlProtocol.slackRefusal(isRemote: shim.remoteHost != nil,
                                                  bridgeReported: shim.bridgeModReported,
                                                  permissionMode: shim.permissionMode) {
            answer(askId, refusal: why)
            return
        }
        let wire = ControlSession.submitControlMessage(ControlProtocol.slackPrompt(asker: asker, text: text), to: shim)
        guard wire["ok"] as? Bool == true, let replyId = wire["replyId"] as? String else {
            answer(askId, refusal: wire["reason"] as? String ?? "the session refused the question")
            return
        }
        logger.notice("[slack] \(shim.keepAliveLogLabel, privacy: .public): question \(askId, privacy: .public) delivered (\(wire["disposition"] as? String ?? "?", privacy: .public))")
        waitForAnswer(askId: askId, sessionKey: sessionKey, replyId: replyId, deadline: Date().addingTimeInterval(Self.answerTimeout))
    }

    /// Polls like `wait_turn`, re-resolving the session each tick: a restart gives it a new shim.
    private func waitForAnswer(askId: String, sessionKey: String, replyId: String, deadline: Date) {
        guard let shim = store.openSession(for: [.key(sessionKey)])?.shim,
              let snap = shim.controlTurnSnapshot(replyId: replyId) else {
            answer(askId, refusal: "the session closed before it answered")
            return
        }
        if snap.turnDone {
            let notes = shim.slackTurnNotes
            answer(askId, text: snap.text ?? "", kind: notes.kind, denied: notes.denied)
            return
        }
        if snap.state == "asking" || snap.state == "permission" {
            answer(askId, refusal: "the session is waiting for Saqoosha on the Mac")
            return
        }
        if Date() > deadline {
            answer(askId, refusal: "the session did not answer within 30 minutes")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForAnswer(askId: askId, sessionKey: sessionKey, replyId: replyId, deadline: deadline)
            }
        }
    }

    private func answer(_ askId: String, text: String, kind: String?, denied: [String]) {
        var message: [String: Any] = ["type": "answer", "askId": askId, "ok": true, "text": text, "denied": denied]
        if let kind { message["kind"] = kind }
        if !send(message) { logger.error("[slack] answer \(askId, privacy: .public) lost: not connected") }
    }

    private func answer(_ askId: String, refusal: String) {
        logger.notice("[slack] question \(askId, privacy: .public) refused: \(refusal, privacy: .public)")
        if !send(["type": "answer", "askId": askId, "ok": false, "reason": refusal]) {
            logger.error("[slack] refusal \(askId, privacy: .public) lost: not connected")
        }
    }
}
