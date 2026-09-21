import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorFile")

/// Files a mirrored session opens travel over the mirror connection itself,
/// host → watching Mac, as `file_begin` / `file_chunk`* / `file_end`; a URL
/// is one `open_url`. Chosen over ssh-ing back to the watcher for two
/// reasons, both measured: the ssh handshake studio → Mac costs ~1.2 s and a
/// 600 KB payload nothing, so the connection that is already up is the fast
/// path; and only a receiver can draw progress, which is what turned a
/// working transfer into "did that do anything?".
///
/// Only a Mac client is sent these (`MirrorSink.acceptsFileTransfers`); the
/// phone never sees the frames. The SSH-remote arrangement has no host Canopy
/// in the path and keeps the script's ssh route.
enum MirrorFileWire {
    static let begin = "file_begin"
    static let chunk = "file_chunk"
    static let end = "file_end"
    static let url = "open_url"
    /// Raw bytes per chunk; base64 makes the line ~350 KB, well under the
    /// 16 MiB line cap both ends enforce.
    static let chunkBytes = 256 * 1024

    static func isFileFrame(_ type: String?) -> Bool {
        type == begin || type == chunk || type == end || type == url
    }

    /// The name a `file_begin` may carry: a bare file name, never a path.
    static func sanitizedName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains("/"), !raw.contains("\0"),
              raw != ".", raw != "..", raw.utf8.count <= 255
        else { return nil }
        return raw
    }

    /// The host name a `file_begin` may carry, used as a directory name.
    static func sanitizedHost(_ raw: String?) -> String {
        let cleaned = (raw ?? "").replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "remote" : String(cleaned.prefix(64))
    }
}

/// Host side: streams one file or URL to one watching Mac.
@MainActor
enum MirrorFileSender {
    static func sendURL(_ url: String, to sink: any MirrorSink) {
        sink.deliver(["type": MirrorFileWire.url, "url": url])
    }

    /// One transfer at a time, process-wide: `open a.pdf b.png` is two
    /// requests in one outbox drain, and two `file_begin`s in flight would
    /// make the receiver drop the first. Each send waits for the last.
    private static var chain: Task<Void, Never>?

    /// False when the file cannot be read at all, so the caller can open it
    /// here instead — it has already told its own caller the request was
    /// taken. Reads on the main actor in `chunkBytes` steps with a yield
    /// between them, so a large file costs many short stalls rather than
    /// one long one. Every chunk is enqueued as it is read; the transient
    /// cost is the base64 of whatever the socket has not yet drained.
    @discardableResult
    static func send(path: String, to sink: any MirrorSink) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let name = MirrorFileWire.sanitizedName(url.lastPathComponent),
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            logger.error("send: cannot read \(path, privacy: .private)")
            return false
        }
        let id = UUID().uuidString
        // The first label of the host name, which is what `hostname -s` gives
        // the script's ssh route, so both land in the same `from-<host>`.
        // The localized name ("Saqoosha's Mac Studio") was tried and split
        // one host across two folders.
        let host = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "remote")
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            defer { try? handle.close() }
            sink.deliver(["type": MirrorFileWire.begin, "id": id, "name": name, "size": size, "host": host])
            logger.notice("send: \(name, privacy: .public) \(size) bytes")
            var sent = 0
            while true {
                let data: Data
                do {
                    guard let d = try handle.read(upToCount: MirrorFileWire.chunkBytes), !d.isEmpty else { break }
                    data = d
                } catch {
                    sink.deliver(["type": MirrorFileWire.end, "id": id, "error": error.localizedDescription])
                    return
                }
                sink.deliver(["type": MirrorFileWire.chunk, "id": id, "data": data.base64EncodedString()])
                sent += data.count
                await Task.yield()
            }
            sink.deliver(["type": MirrorFileWire.end, "id": id])
            logger.notice("send: done, \(sent) bytes")
        }
        return true
    }
}

/// Watching-Mac side: writes an incoming file under `~/Downloads/from-<host>/`
/// and opens it; the pane's overlay reads `current` and `lastError`.
@Observable
final class MirrorFileReceiver {
    struct Transfer: Equatable {
        let id: String
        let name: String
        let host: String
        let size: Int
        var received = 0
        var fraction: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }
    }

    private(set) var current: Transfer?
    /// Shown for a few seconds after a failed transfer; nil otherwise.
    private(set) var lastError: String?
    /// True once a transfer has run long enough to be worth a window; a file
    /// that lands in a blink shows nothing.
    private(set) var showsOverlay = false

    private var handle: FileHandle?
    private var destination: URL?
    private var overlayTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    static let overlayDelay: Duration = .milliseconds(400)
    static let errorHold: Duration = .seconds(4)

    var isOverlayVisible: Bool { (current != nil && showsOverlay) || lastError != nil }

    @MainActor func handle(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case MirrorFileWire.url:
            if let s = frame["url"] as? String, let url = URL(string: s),
               ["http", "https", "mailto"].contains(url.scheme ?? "")
            {
                NSWorkspace.shared.open(url)
            }
        case MirrorFileWire.begin:
            begin(frame)
        case MirrorFileWire.chunk:
            chunk(frame)
        case MirrorFileWire.end:
            end(frame)
        default:
            break
        }
    }

    @MainActor private func begin(_ frame: [String: Any]) {
        abort(reason: nil)
        guard let id = frame["id"] as? String,
              let name = MirrorFileWire.sanitizedName(frame["name"] as? String),
              let size = frame["size"] as? Int, size >= 0
        else {
            logger.error("begin: malformed frame")
            return
        }
        let host = MirrorFileWire.sanitizedHost(frame["host"] as? String)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").appendingPathComponent("from-\(host)")
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            handle = try FileHandle(forWritingTo: dest)
            try handle?.truncate(atOffset: 0)
        } catch {
            fail("Could not write \(name): \(error.localizedDescription)")
            return
        }
        destination = dest
        current = Transfer(id: id, name: name, host: host, size: size)
        showsOverlay = false
        overlayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.overlayDelay)
            guard let self, !Task.isCancelled, self.current?.id == id else { return }
            self.showsOverlay = true
        }
        logger.notice("receiving \(name, privacy: .public) \(size) bytes from \(host, privacy: .public)")
    }

    @MainActor private func chunk(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String, current?.id == id,
              let b64 = frame["data"] as? String, let data = Data(base64Encoded: b64)
        else { return }
        do {
            try handle?.write(contentsOf: data)
            current?.received += data.count
        } catch {
            fail("Could not write \(current?.name ?? "file"): \(error.localizedDescription)")
        }
    }

    @MainActor private func end(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String, let transfer = current, transfer.id == id else { return }
        if let error = frame["error"] as? String {
            fail("\(transfer.name): \(error)")
            return
        }
        try? handle?.close()
        handle = nil
        overlayTask?.cancel()
        let dest = destination
        current = nil
        showsOverlay = false
        destination = nil
        if let dest {
            NSWorkspace.shared.open(dest)
            logger.notice("opened \(transfer.name, privacy: .public)")
        }
    }

    @MainActor private func fail(_ message: String) {
        abort(reason: message)
    }

    /// The connection went while a file was in flight: drop the partial file
    /// and say so, since no `file_end` is coming.
    @MainActor func connectionDropped() {
        guard let name = current?.name else { return }
        abort(reason: "\(name): connection lost")
    }

    /// Drops an in-flight transfer and its partial file. `reason` nil is a
    /// silent supersede (a new `begin` while one was running).
    @MainActor private func abort(reason: String?) {
        overlayTask?.cancel()
        try? handle?.close()
        handle = nil
        if let destination, current != nil { try? FileManager.default.removeItem(at: destination) }
        destination = nil
        current = nil
        showsOverlay = false
        guard let reason else { return }
        logger.error("\(reason, privacy: .public)")
        lastError = reason
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorHold)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}
