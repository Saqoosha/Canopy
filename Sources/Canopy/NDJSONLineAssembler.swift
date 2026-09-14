import Foundation

/// Splits a byte stream into newline-terminated lines, scanning each byte once.
///
/// The previous accumulator searched the whole buffer from its start on every
/// chunk, so one multi-megabyte replay arriving in pipe-sized chunks was
/// rescanned dozens of times: measured 2026-09-14, a 10 MB line took 5.5 s to
/// find its newline, and a phone's live attach stalled for 5 s on exactly that.
struct NDJSONLineAssembler {
    private var buffer = Data()
    /// Bytes of `buffer` already known to contain no newline.
    private var scanned = 0
    /// When the first byte of the line currently being assembled arrived.
    private(set) var pendingSince: Date?

    /// True when a line holds only spaces, tabs and carriage returns.
    static func isBlank(_ line: Data) -> Bool {
        for byte in line where byte != 0x20 && byte != 0x09 && byte != 0x0D { return false }
        return true
    }

    /// Appends a chunk and returns every line it completes, without their newlines.
    mutating func append(_ chunk: Data, at time: Date = Date()) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        if buffer.isEmpty { pendingSince = time }
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[lineStart..<newline]))
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > buffer.startIndex {
            buffer = Data(buffer[lineStart...])
            pendingSince = buffer.isEmpty ? nil : time
        }
        scanned = buffer.count
        return lines
    }
}
