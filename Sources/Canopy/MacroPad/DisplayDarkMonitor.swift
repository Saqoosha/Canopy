import AppKit
import CoreGraphics
import IOKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DisplayDark")

/// Reports whether nobody can see this Mac's screens, so the MacroPad can go
/// dark with them.
///
/// Three signals, measured on an M1 Max in clamshell with an MSI PX32UFWAVE
/// over USB-C (2026-11-19):
///
/// - **Monitor switched off at its button.** With the lid closed the Mac
///   enters clamshell sleep, and `screensDidSleepNotification` arrives first.
///   The monitor's AV service also disappears from the registry while it is
///   off, which is what `externalBrightness` being empty covers on a Mac that
///   stays awake.
/// - **Brightness 0 in the monitor's own OSD.** Visible over DDC/CI as VCP
///   0x10 reading 0. There is no notification; it is polled.
/// - **DDC answers unreliably.** A single read fails often (BetterDisplay was
///   running too), and while the monitor's input is switched to another
///   computer no read succeeds at all (28 minutes, measured). A failed read
///   is therefore "unknown" and keeps the previous verdict rather than
///   reading as lit or dark, so switching the input away leaves the pad lit.
@MainActor
final class DisplayDarkMonitor {
    /// Short enough that the pad follows a brightness change within a few
    /// seconds; one poll costs one DDC round trip per external monitor.
    private static let pollInterval: TimeInterval = 5

    private let onChange: (Bool) -> Void
    private let pollQueue = DispatchQueue(label: "sh.saqoo.Canopy.display-dark", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var pollInFlight = false
    private(set) var isDark = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Starts or stops polling. Stopping keeps the last verdict: it is only
    /// read while enabled, and a re-enable polls at once.
    func setEnabled(_ enabled: Bool) {
        if enabled == (timer != nil) { return }
        logger.notice("Display dark monitor enabled=\(enabled, privacy: .public)")
        if enabled {
            let center = NSWorkspace.shared.notificationCenter
            for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                                   (NSWorkspace.screensDidWakeNotification, false)] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.screensAsleep = asleep
                        if asleep { self.update(builtInActive: false, externalBrightness: []) } else { self.poll() }
                    }
                })
            }
            let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            poll()
        } else {
            timer?.invalidate()
            timer = nil
            observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            observers.removeAll()
        }
    }

    private func poll() {
        guard timer != nil, !pollInFlight else { return }
        pollInFlight = true
        pollQueue.async { [weak self] in
            let builtIn = Self.builtInDisplayActive()
            let external = Self.readExternalBrightness()
            Task { @MainActor in
                guard let self else { return }
                self.pollInFlight = false
                self.update(builtInActive: builtIn, externalBrightness: external)
            }
        }
    }

    private func update(builtInActive: Bool, externalBrightness: [Int?]) {
        let dark = Self.evaluate(screensAsleep: screensAsleep,
                                 builtInActive: builtInActive,
                                 externalBrightness: externalBrightness,
                                 previous: isDark)
        logger.debug("poll dark=\(dark, privacy: .public) builtIn=\(builtInActive, privacy: .public) external=\(String(describing: externalBrightness), privacy: .public)")
        guard dark != isDark else { return }
        isDark = dark
        let readings = externalBrightness.map { $0.map(String.init) ?? "?" }.joined(separator: ",")
        logger.notice("Display dark=\(dark, privacy: .public) screensAsleep=\(self.screensAsleep, privacy: .public) builtIn=\(builtInActive, privacy: .public) external=[\(readings, privacy: .public)]")
        onChange(dark)
    }

    /// The verdict, pure so the probe can reach it. `externalBrightness` has
    /// one entry per external monitor, nil where the DDC read failed.
    nonisolated static func evaluate(screensAsleep: Bool,
                                     builtInActive: Bool,
                                     externalBrightness: [Int?],
                                     previous: Bool) -> Bool {
        if screensAsleep { return true }
        // The built-in panel's brightness is not read, so an active one
        // counts as lit.
        if builtInActive { return false }
        if externalBrightness.isEmpty { return true }
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

    /// One entry per external `DCPAVServiceProxy` (Apple Silicon only; an
    /// Intel Mac has none and reads as "no external monitor").
    nonisolated private static func readExternalBrightness() -> [Int?] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [Int?] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
            else { continue }
            result.append(readBrightness(av))
        }
        return result
    }

    /// DDC/CI "Get VCP Feature" for 0x10. The reply's first two header bytes
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
                return Int(reply[8]) << 8 | Int(reply[9])
            }
            usleep(50_000)
        }
        return nil
    }
}

// Private IOKit SPI used by every DDC tool on Apple Silicon (m1ddc,
// MonitorControl, BetterDisplay).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
