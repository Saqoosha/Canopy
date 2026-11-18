import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "PeerRelay")

/// Carries Claude Code's cross-session messages (SendMessage) between paired Macs.
///
/// The CLI's peer messaging is machine-local. Each session listens on the Unix socket named
/// by `messagingSocketPath` in `~/.claude/sessions/<pid>.json`; a send is one connection
/// carrying NDJSON lines whose `from` is the sender's `uds:` socket, and the receiver answers
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

    /// The CLI's own default. A proxy must sit in the same directory as the socket of the
    /// session that will answer it: the CLI replies to a `uds:` address there without asking.
    nonisolated static let defaultDirectory = "/tmp/cc-socks"
    /// A send carries one message; SendFile can carry files inline, so the cap is generous.
    nonisolated static let maxLineBytes = 32 << 20

    /// Proxy path → the remote session it stands for.
    private var routes: [String: Route] = [:]
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
            guard let pid = Int32(file.dropLast(5)) else { continue }
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
        guard let data = try? Data(contentsOf: Self.routesFile),
              let saved = try? JSONDecoder().decode([String: Route].self, from: data) else { return }
        for (path, route) in saved {
            _ = proxy(for: route, in: (path as NSString).deletingLastPathComponent)
        }
    }

    /// The proxy socket standing for `route`, opened if it is not already.
    func proxy(for route: Route, in directory: String) -> String? {
        let path = (directory as NSString).appendingPathComponent(Self.proxyName(route))
        if routes[path] == route { return path }
        guard let fd = Self.openListener(at: path) else {
            logger.error("could not open proxy \(path, privacy: .public)")
            return nil
        }
        routes[path] = route
        save()
        Self.startAccepting(fd: fd, proxy: path)
        logger.notice("proxy \(path, privacy: .public) → \(route.machineId, privacy: .public) \(route.socket, privacy: .public)")
        return path
    }

    /// 16 hex digits: the CLI accepts `[0-9a-f]{1,16}.sock` as a session socket name, and a
    /// stable name keeps an address valid across daemon restarts.
    nonisolated static func proxyName(_ route: Route) -> String {
        let digest = SHA256.hash(data: Data("\(route.machineId)\n\(route.socket)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? FileManager.default.createDirectory(at: Self.routesFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.routesFile, options: .atomic)
    }

    // MARK: - Sending side

    private func forward(_ line: String, from proxy: String) {
        guard let route = routes[proxy] else { return }
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

    /// Writes a line that arrived from another Mac to a local session's socket. Returns why
    /// it could not, or nil.
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
        let written = await Task.detached { Self.write(payload, to: socket) }.value
        return written ? nil : "could not write to \(socket)"
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

    nonisolated private static func openListener(at path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    nonisolated private static func startAccepting(fd: Int32, proxy: String) {
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    logger.error("accept on \(proxy, privacy: .public) failed: errno \(errno)")
                    close(fd)
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
            if count <= 0 { break }
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

    nonisolated private static func write(_ data: Data, to path: String) -> Bool {
        guard var addr = address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, base + offset, raw.count - offset)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }
}
