import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "PeerRelay")

/// Carries Claude Code's cross-session messages (SendMessage) between paired Macs.
///
/// The CLI's peer messaging is machine-local. Each session listens on the Unix socket named
/// by `messagingSocketPath` in `~/.claude/sessions/<pid>.json`; a send is one connection
/// carrying one JSON line whose `from` is the sender's `uds:` socket, and the receiver answers
/// (replies, hold receipts) by connecting to that `from`. So a session on another Mac is
/// represented here by a proxy socket next to the local ones. A line arriving on a proxy goes
/// to the owning Mac's daemon as `peer_deliver`; that daemon points `from` at a proxy of its
/// own for the sender and writes the line to the real socket. See
/// docs/notes/learnings-cross-mac-peers.md for the measured wire format.
@MainActor
final class PeerRelay {
    static let shared = PeerRelay()

    struct Route: Codable, Hashable, Sendable {
        let machineId: String
        let socket: String
    }

    struct LocalPeer: Sendable {
        let name: String?
        let socket: String
        let cwd: String?
        let status: String?
        let sessionId: String?

        var wire: [String: Any] {
            var row: [String: Any] = ["socket": socket]
            if let name { row["name"] = name }
            if let cwd { row["cwd"] = cwd }
            if let status { row["status"] = status }
            if let sessionId { row["sessionId"] = sessionId }
            return row
        }
    }

    /// The CLI's own default.
    nonisolated static let defaultDirectory = "/tmp/cc-socks"
    /// A line travels inside a JSON-escaped `peer_deliver` frame capped at `NDJSONLineBuffer.maxLineBytes`.
    nonisolated static let maxLineBytes = NDJSONLineBuffer.maxLineBytes / 4
    /// A saved route not used for this long is not reopened at start.
    nonisolated static let routeLifetime: TimeInterval = 7 * 24 * 3600

    private struct Saved: Codable {
        let route: Route
        let used: Date
    }

    private struct Proxy {
        let route: Route
        var used: Date
        let fd: Int32
    }

    /// Proxy path → the remote session it stands for.
    private var proxies: [String: Proxy] = [:]
    private var restored = false

    private static var routesFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"
        return support.appendingPathComponent("Canopy/peer-relay-routes-\(bundle).json")
    }

    // MARK: - Local sessions

    /// Live CLI sessions on this Mac that accept peer messages.
    nonisolated static func localPeers() -> [LocalPeer] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var peers: [LocalPeer] = []
        for file in files where file.hasSuffix(".json") {
            guard let pid = Int32(file.dropLast(5)), pid > 0 else { continue }
            let alive = kill(pid, 0) == 0 || errno == EPERM
            guard alive,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let socket = record["messagingSocketPath"] as? String, !socket.isEmpty else { continue }
            peers.append(LocalPeer(name: record["name"] as? String, socket: socket,
                                   cwd: record["cwd"] as? String, status: record["status"] as? String,
                                   sessionId: record["sessionId"] as? String))
        }
        return peers.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    nonisolated static func localDirectory(_ peers: [LocalPeer]) -> String {
        peers.first.map { ($0.socket as NSString).deletingLastPathComponent } ?? defaultDirectory
    }

    // MARK: - Proxies

    /// Re-opens the proxies a previous daemon handed out, so a session holding one of those
    /// addresses can still answer after an upgrade restart.
    func restore() {
        guard !restored else { return }
        restored = true
        let data: Data
        do {
            data = try Data(contentsOf: Self.routesFile)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("could not read proxy routes: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        let saved: [String: Saved]
        do {
            saved = try JSONDecoder().decode([String: Saved].self, from: data)
        } catch {
            logger.error("could not decode proxy routes: \(error.localizedDescription, privacy: .public)")
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.routeLifetime)
        for (path, entry) in saved where entry.used > cutoff {
            _ = proxy(for: entry.route, in: (path as NSString).deletingLastPathComponent, used: entry.used)
        }
    }

    /// The proxy socket standing for `route`, opened if it is not already.
    func proxy(for route: Route, in directory: String, used: Date = Date()) -> String? {
        let path = (directory as NSString).appendingPathComponent(Self.proxyName(route))
        if proxies[path]?.route == route, Self.isSocket(path) {
            touch(path)
            return path
        }
        guard let fd = Self.openListener(at: path) else { return nil }
        proxies[path] = Proxy(route: route, used: used, fd: fd)
        save()
        Self.startAccepting(fd: fd, proxy: path)
        logger.notice("proxy \(path, privacy: .public) → \(route.machineId, privacy: .public) \(route.socket, privacy: .public)")
        return path
    }

    /// 16 hex digits: the CLI accepts `[0-9a-f]{1,16}.sock` as a session socket name, and a
    /// stable name keeps an address valid across daemon restarts. The bundle id keeps a Debug
    /// and a Release daemon from taking over each other's proxies.
    nonisolated static func proxyName(_ route: Route) -> String {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let digest = SHA256.hash(data: Data("\(bundle)\n\(route.machineId)\n\(route.socket)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    private func touch(_ path: String) {
        guard let last = proxies[path]?.used, Date().timeIntervalSince(last) > 3600 else { return }
        proxies[path]?.used = Date()
        save()
    }

    /// The accept loop on `fd` ended, so the next `proxy(for:)` must open the socket again.
    private func closed(_ path: String, fd: Int32) {
        guard proxies[path]?.fd == fd else { return }
        proxies.removeValue(forKey: path)
    }

    private func save() {
        let saved = proxies.mapValues { Saved(route: $0.route, used: $0.used) }
        do {
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: Self.routesFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.routesFile, options: .atomic)
        } catch {
            logger.error("could not save proxy routes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sending side

    private func forward(_ line: String, from proxy: String) {
        guard let route = proxies[proxy]?.route else {
            logger.error("no route for \(proxy, privacy: .public); dropping a line")
            return
        }
        touch(proxy)
        Task {
            let params: [String: Any] = ["to": route.socket, "line": line,
                                         "fromMachine": MachineIdentity.stableId() ?? "",
                                         "fromMachineName": Self.machineName]
            if case .failure(let failure) = await PeerControl.request(machineId: route.machineId, "peer_deliver", params) {
                logger.error("peer_deliver to \(route.machineId, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            }
        }
    }

    static var machineName: String {
        MachineIdentity.resolvedDisplayName(setting: CanopySettings.shared.machineDisplayName,
                                            fallback: MachineIdentity.defaultDisplayName())
    }

    // MARK: - Receiving side

    /// Writes a line that arrived from another Mac to a local session's socket. The sender's
    /// reply proxy goes next to that socket, since the CLI answers a `uds:` address only there.
    func deliver(to socket: String, line: String, fromMachine: String, fromMachineName: String?) async -> String? {
        let local = await Task.detached { Self.localPeers() }.value
        guard local.contains(where: { $0.socket == socket }) else { return "no live session listens on \(socket)" }
        guard CanopySettings.shared.mirrorPeers[fromMachine] != nil else {
            return "this Mac has no connection to the sending Mac, so a reply could not go back; paste its connection in Settings › Remote"
        }
        guard var message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return "unreadable message"
        }
        if let from = message["from"] as? String, from.hasPrefix("uds:") {
            let sender = String(from.dropFirst(4)).removingPercentEncoding ?? String(from.dropFirst(4))
            guard let proxy = proxy(for: Route(machineId: fromMachine, socket: sender),
                                    in: (socket as NSString).deletingLastPathComponent) else {
                return "could not open a reply socket"
            }
            message = Self.rewrite(message, from: from, to: "uds:\(proxy)", machineName: fromMachineName)
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return "unwritable message" }
        data.append(0x0A)
        let payload = data
        let failure = await Task.detached { Self.write(payload, to: socket) }.value
        return failure.map { "could not write to \(socket): \($0)" }
    }

    /// Points the envelope at the proxy: the top-level `from`, and the opening
    /// `<cross-session-message>` tag the receiving Claude reads its reply address from.
    /// The sender's display name gets its Mac's name so Claude can tell it is remote.
    nonisolated static func rewrite(_ message: [String: Any], from old: String, to new: String,
                                    machineName: String?) -> [String: Any] {
        var message = message
        message["from"] = new
        guard var body = message["message"] as? [String: Any] else { return message }
        if let content = body["content"] as? String {
            body["content"] = rewriteTag(content, from: old, to: new, machineName: machineName)
        } else if let blocks = body["content"] as? [[String: Any]] {
            body["content"] = blocks.map { block -> [String: Any] in
                guard let text = block["text"] as? String else { return block }
                var block = block
                block["text"] = rewriteTag(text, from: old, to: new, machineName: machineName)
                return block
            }
        }
        message["message"] = body
        return message
    }

    nonisolated static func rewriteTag(_ text: String, from old: String, to new: String, machineName: String?) -> String {
        guard let open = text.range(of: "<cross-session-message "),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return text }
        var tag = String(text[open.lowerBound..<close.upperBound])
        tag = tag.replacingOccurrences(of: "from=\"\(old)\"", with: "from=\"\(new)\"")
        let machine = (machineName ?? "").filter { !"\"<>".contains($0) }.trimmingCharacters(in: .whitespaces)
        if !machine.isEmpty, let nameStart = tag.range(of: "from-name=\""),
           let nameEnd = tag.range(of: "\"", range: nameStart.upperBound..<tag.endIndex) {
            tag.replaceSubrange(nameEnd.lowerBound..<nameEnd.lowerBound, with: " on \(machine)")
        }
        return text.replacingCharacters(in: open.lowerBound..<close.upperBound, with: tag)
    }

    // MARK: - Sockets

    nonisolated private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    nonisolated private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    nonisolated private static func openListener(at path: String) -> Int32? {
        func failed(_ step: String) -> Int32? {
            logger.error("could not open proxy \(path, privacy: .public): \(step, privacy: .public) \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        guard var addr = address(path) else {
            logger.error("could not open proxy \(path, privacy: .public): path too long")
            return nil
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return failed("socket") }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let step = bound != 0 ? "bind" : chmod(path, 0o600) != 0 ? "chmod" : listen(fd, 16) != 0 ? "listen" : nil
        if let step {
            let result = failed(step)
            close(fd)
            return result
        }
        return fd
    }

    nonisolated private static func startAccepting(fd: Int32, proxy: String) {
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    logger.error("accept on \(proxy, privacy: .public) failed: errno \(errno)")
                    close(fd)
                    Task { @MainActor in PeerRelay.shared.closed(proxy, fd: fd) }
                    return
                }
                Thread.detachNewThread { readLines(client, proxy: proxy) }
            }
        }
    }

    nonisolated private static func readLines(_ fd: Int32, proxy: String) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        func emit(_ bytes: Data) {
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            Task { @MainActor in PeerRelay.shared.forward(line, from: proxy) }
        }
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                logger.error("read on \(proxy, privacy: .public) failed: errno \(errno); dropping \(buffer.count) bytes")
                return
            }
            if count == 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                emit(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > maxLineBytes {
                logger.error("dropping an oversized line on \(proxy, privacy: .public)")
                return
            }
        }
        emit(buffer)
    }

    /// Returns why the write failed, or nil.
    nonisolated private static func write(_ data: Data, to path: String) -> String? {
        func reason() -> String { String(cString: strerror(errno)) }
        guard var addr = address(path) else { return "path too long" }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return reason() }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return reason() }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return reason() }
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, base + offset, raw.count - offset)
                if sent < 0, errno == EINTR { continue }
                if sent <= 0 { return reason() }
                offset += sent
            }
            return nil
        }
    }
}
