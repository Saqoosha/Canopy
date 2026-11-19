import AppKit
import CoreGraphics
import IOKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DisplayDark")

/// Reports whether this Mac's screens are dark, so a USB MacroPad can go dark
/// with them. Measured on an M1 Max in clamshell with an MSI PX32UFWAVE over
/// USB-C (2026-11-19):
///
/// - Monitor switched off at its button: clamshell sleep posts
///   `screensDidSleepNotification`; on a Mac that stays awake the monitor's
///   AV service disappears from the registry instead.
/// - Brightness 0 in the monitor's OSD: DDC/CI VCP 0x10 reads 0. Polled.
/// - A failed DDC read is unknown and keeps the previous DDC verdict. While
///   the monitor's input is on another computer every read fails (28 min).
///
/// An active built-in panel always counts as lit; its brightness is not read.
@MainActor
final class DisplayDarkMonitor {
    private static let pollInterval: TimeInterval = 5

    private let onChange: () -> Void
    private let pollQueue = DispatchQueue(label: "sh.saqoo.Canopy.display-dark", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    /// The verdict from the last DDC poll, kept apart from sleep so that a
    /// wake followed by failing reads does not inherit the sleep's "dark".
    private var externalDark = false
    /// Whether an external AV service has been seen since launch. Until one
    /// has, an empty list means "not readable here" (Intel, DisplayLink),
    /// not "monitor off".
    private var sawExternal = false
    private var pollInFlight = false
    private var pollAgain = false

    /// False while disabled, so a stale verdict is never applied.
    var isDark: Bool { timer != nil && (screensAsleep || externalDark) }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func setEnabled(_ enabled: Bool) {
        if enabled == (timer != nil) { return }
        logger.notice("Display dark monitor enabled=\(enabled, privacy: .public)")
        if enabled {
            let center = NSWorkspace.shared.notificationCenter
            for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                                   (NSWorkspace.screensDidWakeNotification, false)] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.screensChanged(asleep: asleep) }
                })
            }
            screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            externalDark = false
            let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            poll()
        } else {
            timer?.invalidate()
            timer = nil
            pollAgain = false
            observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            observers.removeAll()
        }
    }

    private func screensChanged(asleep: Bool) {
        guard timer != nil else { return }
        let before = isDark
        screensAsleep = asleep
        report(before: before, reason: asleep ? "screens asleep" : "screens awake")
        if !asleep { poll() }
    }

    /// Skipped while the screens sleep: the verdict is already dark, and DDC
    /// traffic can wake a monitor in standby.
    private func poll() {
        guard timer != nil, !screensAsleep else { return }
        guard !pollInFlight else { pollAgain = true; return }
        pollInFlight = true
        pollQueue.async { [weak self] in
            let builtIn = Self.builtInDisplayActive()
            let external = Self.readExternalBrightness()
            Task { @MainActor in
                // nil: the registry query itself failed, so this poll says nothing.
                guard let self else { return }
                self.pollInFlight = false
                // A poll that a wake overtook read the sleeping state; read again.
                if self.pollAgain { self.pollAgain = false; self.poll(); return }
                guard self.timer != nil, !self.screensAsleep, let external else { return }
                self.update(builtInActive: builtIn, externalBrightness: external)
            }
        }
    }

    private func update(builtInActive: Bool, externalBrightness: [Int?]) {
        let before = isDark
        externalDark = Self.evaluate(builtInActive: builtInActive,
                                     externalBrightness: externalBrightness,
                                     sawExternal: sawExternal,
                                     previous: externalDark)
        if !externalBrightness.isEmpty { sawExternal = true }
        let readings = externalBrightness.map { $0.map(String.init) ?? "?" }.joined(separator: ",")
        logger.debug("poll dark=\(self.externalDark, privacy: .public) builtIn=\(builtInActive, privacy: .public) external=[\(readings, privacy: .public)]")
        report(before: before, reason: "builtIn=\(builtInActive) external=[\(readings)]")
    }

    private func report(before: Bool, reason: String) {
        guard isDark != before else { return }
        logger.notice("Display dark=\(self.isDark, privacy: .public) \(reason, privacy: .public)")
        onChange()
    }

    /// The DDC verdict, pure so the probe can reach it. `externalBrightness`
    /// has one entry per external monitor, nil where the read failed.
    nonisolated static func evaluate(builtInActive: Bool,
                                     externalBrightness: [Int?],
                                     sawExternal: Bool,
                                     previous: Bool) -> Bool {
        if builtInActive { return false }
        if externalBrightness.isEmpty { return sawExternal ? true : previous }
        if externalBrightness.contains(where: { ($0 ?? 0) > 0 }) { return false }
        if externalBrightness.allSatisfy({ $0 == 0 }) { return true }
        return previous
    }

    // MARK: - Hardware reads (pollQueue)

    nonisolated private static func builtInDisplayActive() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
        }
    }

    /// One entry per external `DCPAVServiceProxy` (Apple Silicon only).
    nonisolated private static func readExternalBrightness() -> [Int?]? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: [Int?] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            result.append(IOAVServiceCreateWithService(kCFAllocatorDefault, service)
                .flatMap { readBrightness($0.takeRetainedValue()) })
        }
        return result
    }

    /// DDC/CI "Get VCP Feature" for 0x10. The reply's length and opcode bytes
    /// arrive garbled on this path (measured: `6e 51 be 00 10 …` where the
    /// spec says `6e 88 02 00 10 …`), so only the result code and the echoed
    /// opcode are checked.
    ///
    /// The request is written twice, 10 ms apart, as m1ddc does. Measured on
    /// the PX32UFWAVE: one write then a read succeeded 0/20 times (with a
    /// 50 ms or 150 ms wait); two writes then a read, 17/20.
    nonisolated private static func readBrightness(_ av: CFTypeRef) -> Int? {
        let code: UInt8 = 0x10
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<5 {
            for _ in 0..<2 {
                usleep(10_000)
                var write = request
                _ = IOAVServiceWriteI2C(av, 0x37, 0x51, &write, UInt32(write.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if IOAVServiceReadI2C(av, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               reply[3] == 0x00, reply[4] == code {
                let max = Int(reply[6]) << 8 | Int(reply[7])
                let current = Int(reply[8]) << 8 | Int(reply[9])
                if max > 0, current <= max { return current }
            }
            usleep(50_000)
        }
        return nil
    }
}

// Private IOKit SPI, as used by m1ddc, MonitorControl and BetterDisplay.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
