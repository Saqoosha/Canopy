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
    /// helper, so this process never writes the key anywhere.
    nonisolated static let headersHelper = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/scripts/saqoolaude-mcp-headers.sh")
    static let answerTimeout: TimeInterval = 30 * 60
    /// Under `ControlClient.requestTimeout`, so the GUI hears which hop failed.
    static let requestTimeout: Duration = .seconds(10)
    /// The Worker closes the older socket with this when another Mac connects.
    static let replacedCloseCode = 4000
    private static let maxBackoff: TimeInterval = 60

    private let store: SessionStore
    private var task: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 2
    private var pingTimer: Timer?
    private var waiters: [String: CheckedContinuation<Result<[String: Any], ControlProtocol.ControlError>, Never>] = [:]
    private var stopped = false
    /// Why the bridge is not connected, for the GUI's bind request.
    private var lastProblem = "not connected to the Saqoolaude Worker"
    /// Answers produced while disconnected, sent once a socket is up again.
    private var outbox: [[String: Any]] = []
    /// One question per session at a time; later ones wait here, so each answer carries its own gate notes.
    private var busySessions: Set<String> = []
    private var waitingAsks: [String: [[String: Any]]] = [:]

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
        logger.notice("Slack bridge stopped; \(self.busySessions.count, privacy: .public) question(s) left unanswered")
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.headersHelper.path) else {
            lastProblem = "the saqoolaude headers helper is missing"
            logger.error("no saqoolaude headers helper at \(Self.headersHelper.path, privacy: .public)")
            scheduleReconnect(after: Self.maxBackoff)
            return
        }
        Task {
            let header = await Self.authorizationHeader()
            guard !stopped else { return }
            guard case .success(let authorization) = header else {
                if case .failure(let why) = header {
                    lastProblem = why.message
                    logger.error("no Authorization header: \(why.message, privacy: .public)")
                }
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
            let pending = outbox
            outbox.removeAll()
            for message in pending { sendAnswer(message) }
        }
    }

    /// Runs the helper in its own process group off the main thread. Its 1Password mount
    /// blocks while the app is locked, so after 10 s the whole group is killed: killing the
    /// shell alone would leave its blocked reader behind. The output is never logged.
    private nonisolated static func authorizationHeader() async -> Result<String, ControlProtocol.ControlError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runHeadersHelper())
            }
        }
    }

    private nonisolated static func runHeadersHelper() -> Result<String, ControlProtocol.ControlError> {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return .failure(.init("pipe failed (errno \(errno))")) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        // Typed apart: the CI compiler infers the literal's element type from strdup's parameter.
        let argv: [String] = ["/bin/sh", headersHelper.path]
        let args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        defer {
            args.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attr, args + [nil], environ)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return .failure(.init("could not start the headers helper (errno \(spawned))"))
        }
        let killer = DispatchWorkItem { kill(-pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let timedOut = killer.isCancelled == false && (status & 0x7f) == SIGKILL
        killer.cancel()
        if timedOut { return .failure(.init("the headers helper timed out (is 1Password locked?)")) }
        guard (status & 0x7f) == 0, (status >> 8) & 0xff == 0 else {
            return .failure(.init("the headers helper failed (status \(status))"))
        }
        guard let headers = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let authorization = headers["Authorization"] else {
            return .failure(.init("the headers helper printed no Authorization header"))
        }
        return .success(authorization)
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
                    self.connectionEnded(task, error)
                    return
                }
                guard let self, self.task === task else { return }
                self.backoff = 2
                if case .string(let text) = message { self.handle(text) }
            }
        }
    }

    private func connectionEnded(_ task: URLSessionWebSocketTask, _ error: Error) {
        // Both read before `dropConnection`, whose cancel would overwrite the close code.
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let closeCode = task.closeCode.rawValue
        dropConnection()
        if closeCode == Self.replacedCloseCode {
            lastProblem = "another Mac took over the Slack bridge"
            logger.error("another Mac connected to the Saqoolaude Worker; this one stops (turn canopy.slackBridgeEnabled off on one of them)")
            return
        }
        if let status, status != 101 {
            lastProblem = "the Saqoolaude Worker refused the connection (HTTP \(status))"
            logger.error("the Saqoolaude Worker answered HTTP \(status, privacy: .public)")
        } else {
            lastProblem = "not connected to the Saqoolaude Worker"
            logger.notice("Worker connection ended: \(error.localizedDescription, privacy: .public)")
        }
        scheduleReconnect()
    }

    /// A ping every 30 s finds a dead link; a failed one ends the socket.
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

    private func scheduleReconnect(after delay: TimeInterval? = nil) {
        let delay = delay ?? backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.task == nil else { return }
                self.connect()
            }
        }
    }

    private static func encode(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func send(_ message: [String: Any]) -> Bool {
        guard let task, let text = Self.encode(message) else { return false }
        Task {
            do { try await task.send(.string(text)) } catch {
                logger.error("send \(message["type"] as? String ?? "?", privacy: .public) to the Worker failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// An answer is kept until a socket takes it: one that fails to send goes back in the outbox.
    private func sendAnswer(_ message: [String: Any]) {
        guard let task, let text = Self.encode(message) else {
            outbox.append(message)
            return
        }
        Task { [weak self] in
            do { try await task.send(.string(text)) } catch {
                guard let self else { return }
                // A newer socket may already have flushed the outbox; send there instead of waiting.
                if let current = self.task, current !== task {
                    self.sendAnswer(message)
                } else {
                    logger.notice("[slack] answer \(message["askId"] as? String ?? "?", privacy: .public) kept for the next connection")
                    self.outbox.append(message)
                }
            }
        }
    }

    // MARK: - Requests from this Mac (bind, unbind, list)

    /// One request to the Worker and its one reply (`bound`, `unbound`, `bindings` or `error`).
    func request(_ type: String, _ params: [String: Any]) async -> Result<[String: Any], ControlProtocol.ControlError> {
        let requestId = UUID().uuidString.lowercased()
        var message = params
        message["type"] = type
        message["requestId"] = requestId
        guard send(message) else { return .failure(ControlProtocol.ControlError(lastProblem)) }
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
            enqueueAsk(message)
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

    private func enqueueAsk(_ message: [String: Any]) {
        guard let askId = message["askId"] as? String else {
            logger.error("ask frame without an askId")
            return
        }
        guard let sessionKey = message["sessionKey"] as? String,
              message["asker"] is String, message["text"] is String else {
            answer(askId, refusal: "the question arrived incomplete")
            return
        }
        if busySessions.contains(sessionKey) {
            waitingAsks[sessionKey, default: []].append(message)
            logger.notice("[slack] question \(askId, privacy: .public) waits for the session's previous one")
            return
        }
        busySessions.insert(sessionKey)
        handleAsk(askId: askId, sessionKey: sessionKey, asker: message["asker"] as! String, text: message["text"] as! String,
                  fromOwner: message["owner"] as? Bool == true)
    }

    private func finishAsk(_ sessionKey: String) {
        busySessions.remove(sessionKey)
        guard var queue = waitingAsks[sessionKey], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waitingAsks[sessionKey] = queue.isEmpty ? nil : queue
        enqueueAsk(next)
    }

    private func handleAsk(askId: String, sessionKey: String, asker: String, text: String, fromOwner: Bool) {
        guard let session = store.openSession(for: [.key(sessionKey)]), let shim = session.shim else {
            answer(askId, refusal: "the session is not open on Saqoosha's Mac", session: sessionKey)
            return
        }
        let prompt: String
        switch ControlProtocol.slackDelivery(asker: asker, text: text, fromOwner: fromOwner, isRemote: shim.remoteHost != nil,
                                             gateReady: shim.slackGateReady, permissionMode: shim.permissionMode) {
        case .failure(let why):
            answer(askId, refusal: why.message, session: sessionKey)
            return
        case .success(let marked):
            prompt = marked
        }
        let wire = ControlSession.submitControlMessage(prompt, to: shim)
        guard wire["ok"] as? Bool == true, let replyId = wire["replyId"] as? String else {
            answer(askId, refusal: wire["reason"] as? String ?? "the session refused the question", session: sessionKey)
            return
        }
        logger.notice("[slack] \(shim.keepAliveLogLabel, privacy: .public): question \(askId, privacy: .public) delivered (\(wire["disposition"] as? String ?? "?", privacy: .public))")
        waitForAnswer(askId: askId, sessionKey: sessionKey, replyId: replyId, deadline: Date().addingTimeInterval(Self.answerTimeout))
    }

    /// Polls like `wait_turn`. A restarted session no longer knows the reply id, which ends the wait.
    private func waitForAnswer(askId: String, sessionKey: String, replyId: String, deadline: Date) {
        guard !stopped else { return }
        guard let shim = store.openSession(for: [.key(sessionKey)])?.shim,
              let snap = shim.controlTurnSnapshot(replyId: replyId) else {
            answer(askId, refusal: "the session closed or restarted before it answered", session: sessionKey)
            return
        }
        if snap.turnDone {
            let reply = (snap.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else {
                answer(askId, refusal: "the session finished without a reply", session: sessionKey)
                return
            }
            let notes = shim.slackTurnNotes
            var message: [String: Any] = ["type": "answer", "askId": askId, "ok": true, "text": reply, "denied": notes.denied]
            if let kind = notes.kind { message["kind"] = kind }
            sendAnswer(message)
            finishAsk(sessionKey)
            return
        }
        if Date() > deadline {
            answer(askId, refusal: "the session did not answer within \(Int(Self.answerTimeout / 60)) minutes", session: sessionKey)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForAnswer(askId: askId, sessionKey: sessionKey, replyId: replyId, deadline: deadline)
            }
        }
    }

    private func answer(_ askId: String, refusal: String, session sessionKey: String? = nil) {
        logger.notice("[slack] question \(askId, privacy: .public) refused: \(refusal, privacy: .public)")
        sendAnswer(["type": "answer", "askId": askId, "ok": false, "reason": refusal])
        if let sessionKey { finishAsk(sessionKey) }
    }
}
