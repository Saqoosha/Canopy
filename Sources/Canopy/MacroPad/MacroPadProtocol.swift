import Foundation

/// Wire protocol for the Canopy MacroPad: newline-delimited ASCII over a USB
/// CDC data port. Deliberately human-typable so the whole link can be driven
/// from `screen /dev/cu.usbmodemXXXX` during bring-up.
///
/// This file is the protocol layer and knows nothing about serial ports; the
/// physical layer is `MacroPadDevice`. The split is what lets the transport
/// change — a BLE characteristic, say — without touching the grammar.
enum MacroPadCommand: Equatable, Sendable {
    /// `C <idx> <rrggbb>` — set one key's color, held steady.
    case color(index: Int, rgb: UInt32)
    /// `S <idx> <rrggbb> <period_ms> <floor_pct>` — breathe on a sine between
    /// `floor_pct` of the color and full. Introduced in protocol v2; shipping
    /// firmware reports 3.
    ///
    /// The animation runs on the device, not here. Driving a smooth sine from
    /// the host would mean ~50 `C` per second per key, and any hitch on the
    /// main actor would show up as a stutter; one `S` costs one line, ever.
    ///
    /// One firmware guarantee this side depends on: re-sending a command whose
    /// colour, period and floor already match the key's target is a no-op that
    /// does **not** restart the phase, so a full re-push is always safe.
    ///
    /// The firmware does NOT de-phase keys started together — an early version
    /// did, and it was removed because it conflicted with starting at the
    /// floor. Keys drift apart only because sessions change state at different
    /// moments, which is why `MacroPadController.fullPush` must not blank
    /// everything first: that would turn every key into a fresh
    /// steady-to-breathing transition, and those *do* restart the phase.
    case breathe(index: Int, rgb: UInt32, periodMs: Int, floorPercent: Int)
    /// `B <0-100>` — global brightness. The firmware multiplies this into
    /// every channel, which is why `SessionActivity.ledColor` sends
    /// full-scale values (see the note there).
    case brightness(percent: Int)
    /// `P` — ping; the device answers `PONG`.
    case ping
    /// `R` — all keys off.
    case reset

    var line: String {
        switch self {
        // `%ld`, not `%d`: Swift's `Int` is 64-bit and `%d` reads 32.
        case .color(let index, let rgb):
            return String(format: "C %ld %06lx", index, rgb & 0x00FF_FFFF)
        case .breathe(let index, let rgb, let periodMs, let floorPercent):
            return String(
                format: "S %ld %06lx %ld %ld",
                index, rgb & 0x00FF_FFFF, periodMs, min(100, max(0, floorPercent))
            )
        case .brightness(let percent):
            return "B \(min(100, max(0, percent)))"
        case .ping:
            return "P"
        case .reset:
            return "R"
        }
    }

    var wireBytes: Data { Data((line + "\n").utf8) }
}

/// Everything the device is allowed to say on the data port. Anything else is
/// dropped by the decoder rather than surfaced — the firmware keeps its debug
/// output on the separate console port, so an unrecognised line here means
/// either a firmware regression or that we opened the wrong port, and neither
/// is something to act on mid-stream.
enum MacroPadEvent: Equatable, Sendable {
    /// `HELLO <ver> <keys>`. Sent when the *host opens the data port*, not at
    /// device power-on — a power-on banner would be written before anyone is
    /// listening and lost. It therefore also arrives after a device reset,
    /// which is why the controller treats it as "device state is unknown,
    /// re-push everything" rather than as a one-time greeting.
    ///
    /// The version gates `S`: firmware reporting 1 has no breathe verb and
    /// would answer `ERR unknown S`, leaving those keys dark with only a log
    /// line to explain it. See `MacroPadController.command(for:at:)`.
    case hello(version: Int?, keyCount: Int?)
    /// `PONG <ver> <keys>` — answer to `P`. Carries the identity too, which is
    /// a cheap safety net rather than a designed-for path: the firmware fixes
    /// its key count at boot, so a physically swapped pad re-enumerates and
    /// comes back through the disconnect path instead.
    case pong(version: Int?, keyCount: Int?)
    /// `K <idx> <0|1>` — key edge. The firmware debounces (15 ms) and only
    /// emits settled edges, so these are trusted verbatim; there is
    /// deliberately no host-side debounce to double-filter them.
    case key(index: Int, pressed: Bool)
    /// `ERR <msg>` — anything the device wants to report. Not only rejected
    /// commands: the firmware also uses it for wiring faults (`ERR i2c …`),
    /// a missing data CDC, and two different crash reports: `ERR fatal …`
    /// immediately before it reboots itself, and `ERR fatal-halted …` from a
    /// board that crashed too soon after boot to risk a reset and is sitting
    /// there red — the second is re-sent to every host that connects.
    /// `MacroPadController` keys off the `fatal` prefix, which catches both.
    case deviceError(String)
}

/// Incremental line decoder. Serial reads arrive in arbitrary chunks, so
/// partial lines have to survive between reads.
struct MacroPadLineDecoder {
    /// A CDC port that is not the one we think it is (a REPL console, say)
    /// can emit a long run of bytes with no newline in it. Cap the carry-over
    /// so a wrong-port probe can't grow the buffer without bound; the cap is
    /// far above any legal line (`HELLO 1 4` is nine bytes).
    static let maxBufferedBytes = 4096

    private var buffer = Data()
    /// True between an overflow and the newline that ends the offending line.
    private var isResyncing = false

    mutating func feed(_ data: Data) -> [MacroPadEvent] {
        buffer.append(data)
        var events: [MacroPadEvent] = []

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if isResyncing {
                // The tail of the over-long line. Its head is gone, so it can
                // only be garbage.
                isResyncing = false
                continue
            }
            // The overflow guard below only sees lines that arrive with NO
            // newline. A single chunk carrying a huge line *and* its newline
            // never touches it, so the length has to be checked here too —
            // otherwise the forged-`K` path the resync closes is still open
            // through the other door.
            if lineBytes.count > Self.maxBufferedBytes { continue }
            if let event = Self.parse(lineBytes) {
                events.append(event)
            }
        }

        if buffer.count > Self.maxBufferedBytes {
            // Discard everything and skip to the next newline, rather than
            // keeping the tail. Keeping it *guarantees* the next newline emits
            // one fused `[garbage][real line]`, whose first token comes from
            // the garbage — and since `parse` ignores trailing fields, garbage
            // beginning `K 3 1` would be read as a key press and would move
            // the user's focused pane. That is exactly the failure the
            // drop-a-partial-`K` rule exists to prevent, arriving through the
            // back door. Losing one line and resyncing cleanly is cheaper.
            buffer.removeAll(keepingCapacity: true)
            isResyncing = true
        }
        return events
    }

    /// Forget any partial line. Called on reconnect so a half-line from the
    /// previous connection can't fuse with the first line of the new one.
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        isResyncing = false
    }

    static func parse(_ bytes: some Collection<UInt8>) -> MacroPadEvent? {
        // `decoding:` never fails (invalid bytes become U+FFFD), which is what
        // we want: a garbled line degrades to an unrecognised verb and is
        // dropped, instead of throwing on a port that isn't ours.
        parse(String(decoding: bytes, as: UTF8.self))
    }

    static func parse(_ line: String) -> MacroPadEvent? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\t" })
        guard let verb = fields.first else { return nil }
        let args = fields.dropFirst()

        switch verb {
        case "HELLO":
            return .hello(version: intArg(args, 0), keyCount: intArg(args, 1))
        case "PONG":
            return .pong(version: intArg(args, 0), keyCount: intArg(args, 1))
        case "K":
            // Exactly two fields, a non-negative index, and a state that is
            // literally 0 or 1. Every loosening here is a way for garbage to
            // move the user's focused pane: a missing field defaulted to key
            // 0, trailing junk making `K 3 1 <noise>` look well-formed, or
            // `raw != 0` accepting a corrupted `2` as a press.
            guard args.count == 2,
                  let index = intArg(args, 0), index >= 0,
                  let raw = intArg(args, 1), raw == 0 || raw == 1
            else { return nil }
            return .key(index: index, pressed: raw == 1)
        case "ERR":
            return .deviceError(args.joined(separator: " "))
        default:
            return nil
        }
    }

    private static func intArg(_ args: some Collection<Substring>, _ offset: Int) -> Int? {
        guard offset < args.count else { return nil }
        return Int(args[args.index(args.startIndex, offsetBy: offset)])
    }
}
