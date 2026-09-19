import Compression
import Foundation

/// The bytes on a mirror socket: NDJSON, with large lines optionally sent compressed.
///
/// A plain frame is one JSON object followed by `\n`. A compressed frame is the header
/// `Z <n> <m>\n` followed by exactly `n` bytes of Brotli (`Compression`'s
/// `COMPRESSION_BROTLI`, a standard Brotli stream `brotli -d` can read) that decode to the
/// `m`-byte JSON object, no trailing newline. `Z` cannot begin a JSON value, so a reader
/// tells the two apart from the first byte. `m` is in the header so the reader allocates
/// once and can refuse an oversize line before decoding any of it.
///
/// Compression is per connection and opt-in: a client puts `"compress": "br"` in its
/// `attach`, and every line the server sends it from `attach_ok` on — that one included —
/// is a `Z` frame when large enough. The phone does not ask (Canopy-Mobile has no decoder
/// yet), so it keeps getting plain lines. Only the CLIENT side reads `Z` frames: nothing
/// compresses toward the server, and a server that decoded them would let an unauthenticated
/// peer expand ~60 wire bytes into 16 MiB per frame ahead of the token check (16 MiB of
/// zeros is a 14-byte Brotli stream), so its buffer refuses them.
///
/// Why: a Mac's mirror pane receives the whole transcript in one `get_session` response, and
/// that line is text — measured 2026-09-19, a 1.9 MB replay over a 150 KB/s uplink was 13 s
/// of the 16 s a pane took to open. Images were already moved off the replay for the phone
/// (`deferringReadImagesForMirror`); this covers what is left, which is JSON.
///
/// Why Brotli, measured on a 4.28 MB session JSONL: Foundation's `.zlib` 4.17× in 59 ms,
/// `.lzfse` 4.83× in 23 ms, `COMPRESSION_BROTLI` 4.88× in 16 ms, `.lzma` 6.08× in 595 ms.
/// The framework's Brotli has no level knob (the CLI's q11 reaches 6.35× but takes 4.6 s);
/// LZMA's extra ratio buys ~0.5 s of wire on a 1.9 MB replay at 150 KB/s and costs ~0.3 s
/// of encode on every link, so it is a wash where it helps and a loss on a LAN.
enum MirrorWire {
    /// The value of the `compress` key both sides exchange at attach (HTTP's token for Brotli).
    static let compressionName = "br"
    /// Lines shorter than this go out plain: the streaming deltas are a few hundred bytes of
    /// mostly unique text, not worth an encode call each.
    static let compressThreshold = 4096

    /// One JSON line as the bytes to put on the socket: plain, or a `Z` frame when the
    /// connection negotiated compression and the line is large enough to gain from it.
    static func encode(line: Data, compress: Bool) -> Data {
        if compress, line.count >= compressThreshold,
           let packed = brotli(line), packed.count < line.count {
            var frame = Data("Z \(packed.count) \(line.count)\n".utf8)
            frame.append(packed)
            return frame
        }
        var frame = line
        frame.append(0x0A)
        return frame
    }

    /// The JSON line inside a `Z` frame's payload, or nil when the bytes do not decode to
    /// exactly `rawCount` bytes. Re-checks the size limit the framer already applied, since
    /// a `Frame` can be built by hand.
    static func decode(compressed payload: Data, rawCount: Int) -> Data? {
        guard rawCount >= 0, rawCount <= NDJSONLineBuffer.maxLineBytes else { return nil }
        guard rawCount > 0 else { return payload.isEmpty ? Data() : nil }
        guard !payload.isEmpty else { return nil }
        // One spare byte, so a stream longer than `rawCount` writes past it and fails the
        // equality whatever the codec reports for an undersized destination (Brotli: 0,
        // measured; zlib: dst_size, per the header).
        let capacity = rawCount + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        guard written == rawCount else { return nil }
        out.count = rawCount
        return out
    }

    private static func brotli(_ line: Data) -> Data? {
        // Brotli can expand incompressible input by a few bytes; a result that does not fit is
        // reported as 0 and the caller sends the line plain.
        let capacity = line.count
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            line.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, line.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

/// Accumulates socket bytes and yields complete frames: newline-terminated lines, or the
/// payload of a `Z` frame once all of it has arrived.
final class NDJSONLineBuffer: @unchecked Sendable {
    enum Frame: Equatable {
        /// One JSON line, newline stripped.
        case line(Data)
        /// A `Z` frame's Brotli bytes and the line length its header promised, for `MirrorWire.decode`.
        case compressed(Data, rawCount: Int)
    }

    /// Above the largest legitimate line (a base64 `index.js`, ~7 MB); a line or a `Z` length past it ends the stream.
    static let maxLineBytes = 16 << 20
    /// 20 bytes holds `Z <8 digits> <8 digits>\n`; 24 leaves slack.
    static let maxHeaderBytes = 24
    private let lock = NSLock()
    private var buffer = Data()
    /// False on the server, which nothing compresses toward (see `MirrorWire`).
    private let acceptsCompressed: Bool

    init(acceptsCompressed: Bool) {
        self.acceptsCompressed = acceptsCompressed
    }

    /// Complete frames, or nil once the stream is unusable: a line or `Z` length over
    /// `maxLineBytes`, a malformed `Z` header, or a `Z` frame this side does not accept.
    /// The offending bytes stay at the head, so every later call is nil too; the caller
    /// closes the connection.
    func append(_ chunk: Data) -> [Frame]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var frames: [Frame] = []
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == UInt8(ascii: "Z") {
                guard acceptsCompressed else { return nil }
                // `Z <n> <m>\n` then n bytes, counted: a pending payload costs a 24-byte
                // header parse per chunk, not a scan.
                let headerEnd = buffer.prefix(Self.maxHeaderBytes).firstIndex(of: 0x0A)
                guard let headerEnd else {
                    if buffer.count >= Self.maxHeaderBytes { return nil }
                    break
                }
                let fields = String(decoding: buffer[buffer.startIndex..<headerEnd], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[0] == "Z",
                      let count = Int(fields[1]), count >= 0, count <= Self.maxLineBytes,
                      let rawCount = Int(fields[2]), rawCount >= 0, rawCount <= Self.maxLineBytes else { return nil }
                let payloadStart = buffer.index(after: headerEnd)
                guard buffer.distance(from: payloadStart, to: buffer.endIndex) >= count else { break }
                let payloadEnd = buffer.index(payloadStart, offsetBy: count)
                frames.append(.compressed(buffer.subdata(in: payloadStart..<payloadEnd), rawCount: rawCount))
                buffer.removeSubrange(buffer.startIndex..<payloadEnd)
                continue
            }
            guard let range = buffer.range(of: Data([0x0A])) else {
                if buffer.count > Self.maxLineBytes { return nil }
                break
            }
            guard buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= Self.maxLineBytes else { return nil }
            frames.append(.line(buffer.subdata(in: buffer.startIndex..<range.lowerBound)))
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        }
        return frames
    }

    /// The JSON lines the frames carry, decoding compressed ones on the way; nil when a
    /// payload does not decode, on which the caller closes rather than skips.
    static func lines(from frames: [Frame]) -> [Data]? {
        var lines: [Data] = []
        lines.reserveCapacity(frames.count)
        for frame in frames {
            switch frame {
            case .line(let data):
                lines.append(data)
            case .compressed(let payload, let rawCount):
                guard let line = MirrorWire.decode(compressed: payload, rawCount: rawCount) else { return nil }
                lines.append(line)
            }
        }
        return lines
    }
}
