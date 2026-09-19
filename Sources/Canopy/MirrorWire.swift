import Compression
import Foundation

/// The bytes on a mirror socket: NDJSON, with large lines optionally sent compressed.
///
/// A plain frame is one JSON object followed by `\n`. A compressed frame is the header
/// `Z <n> <m>\n` followed by exactly `n` bytes of Brotli (`Compression`'s
/// `COMPRESSION_BROTLI`, a standard Brotli stream `brotli -d` can read) that decode to the
/// `m`-byte JSON object, no trailing newline. `Z` cannot begin a JSON value, so a reader that
/// knows the frame can tell the two apart from the first byte, and one that does not would
/// have rejected the line as bad JSON rather than misreading it. `m` is in the header so the
/// reader allocates once and can refuse an oversize line before decoding any of it.
///
/// Compression is per connection and opt-in: a client puts `"compress": "br"` in its
/// `attach`, the server echoes it in `attach_ok`, and only then does that connection carry
/// `Z` frames. The phone does not ask (Canopy-Mobile has no decoder yet), so it keeps getting
/// plain lines; a reader accepts `Z` frames whether or not it asked, since nothing else can
/// send them.
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
    /// Lines shorter than this go out plain: the streaming deltas are a few hundred bytes each,
    /// and a frame header plus the codec's own overhead would not shrink them.
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
    /// exactly `rawCount` bytes. The size limit is applied by the framer, off the header.
    static func decode(compressed payload: Data, rawCount: Int) -> Data? {
        guard rawCount >= 0, rawCount <= NDJSONLineBuffer.maxLineBytes else { return nil }
        guard rawCount > 0 else { return payload.isEmpty ? Data() : nil }
        var out = Data(count: rawCount)
        let written = out.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, rawCount,
                    src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        // A short count is a truncated or foreign stream. A stream that would run past
        // `rawCount` is cut off at the buffer and comes back as exactly `rawCount`; that
        // truncated line then fails the JSON parse in the receiver and is logged there.
        return written == rawCount ? out : nil
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

    /// Above the largest legitimate line (a base64 `index.js`, ~7 MB); a peer that never sends a newline is cut off here.
    static let maxLineBytes = 16 << 20
    /// `Z`, a space, two decimal lengths of up to 16 MiB with a space between, `\n`.
    private static let maxHeaderBytes = 24
    private let lock = NSLock()
    private var buffer = Data()

    /// Complete frames, or nil once the stream is unusable: an unterminated line, a `Z`
    /// header naming a length over `maxLineBytes`, or a malformed `Z` header. A nil is not
    /// recoverable; the caller closes the connection.
    func append(_ chunk: Data) -> [Frame]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var frames: [Frame] = []
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == UInt8(ascii: "Z") {
                // `Z <n> <m>\n` then n bytes. Counted, never scanned, so a multi-megabyte
                // payload arriving in small chunks costs nothing per chunk.
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
            frames.append(.line(buffer.subdata(in: buffer.startIndex..<range.lowerBound)))
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        }
        return frames
    }

    /// The JSON lines the frames carry, decoding compressed ones on the way; nil when a
    /// payload does not decode, which is as unrecoverable as a malformed header.
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
