import Foundation
import IOKit
import IOKit.serial
import os
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MacroPad")

/// Physical layer for the MacroPad: finds the device's USB CDC **data** port,
/// opens it, and moves bytes. Knows nothing about colors or sessions — the
/// protocol lives in `MacroPadProtocol`, the meaning in `MacroPadController`.
///
/// Serial, not HID, on purpose: a `/dev/cu.*` is ordinary file I/O, so there
/// is no Input Monitoring TCC prompt, no entitlement, and nothing for
/// Hardened Runtime to object to. The one hard requirement is that Canopy is
/// **not** sandboxed (it isn't — no `com.apple.security.app-sandbox` in
/// `Canopy.entitlements`, and it spawns a Node subprocess besides). If that
/// ever changes, this whole file stops working and the design needs revisiting
/// rather than patching.
///
/// Not `@MainActor`: everything runs on `queue`, and `stop(sendingReset:)`
/// must be able to block the main thread at `applicationWillTerminate` long
/// enough to flush an `R`. Outputs are hopped to the main actor one at a time
/// so the controller sees them in wire order.
final class MacroPadDevice: @unchecked Sendable {
    enum Output: Sendable {
        /// A data port answered a probe. Carries the callout path for logs.
        case connected(path: String)
        /// Port closed — unplug, crash, or a failed write. The controller
        /// drops its diff cache on this so the next connect re-pushes.
        case disconnected
        case event(MacroPadEvent)
    }

    /// Where a probe-ready file descriptor comes from. The two cases are the
    /// only transport-specific part of this class: everything from `adopt`
    /// onward — the read source, `writeBytes`, the decoder — works on any fd.
    enum Endpoint: Equatable {
        case serial(path: String, interfaceNumber: Int)
        case tcp(MacroPadRemoteEndpoint)

        /// What logs say. `adopt` takes this rather than a path so a TCP link
        /// reads as `mbp:8765` instead of an empty or fabricated device path.
        var label: String {
            switch self {
            case .serial(let path, _): return path
            case .tcp(let endpoint): return endpoint.displayLabel
            }
        }
    }

    /// `boot.py` sets this via `supervisor.set_usb_identification`. Matching on
    /// it rather than on a `/dev/cu.usbmodemNNNN` path is the whole point: the
    /// numeric suffix changes with the port and across reboots.
    static let expectedProductName = "Canopy MacroPad"
    /// CircuitPython's USB vendor id.
    ///
    /// The product id is measured (`0x80F8` on CircuitPython 10.2.1, board id
    /// `adafruit_qtpy_rp2040`) but deliberately NOT part of the match: it is a
    /// property of the board and the CircuitPython build, not of this project,
    /// so a firmware update could move it. Pinning it would fail closed —
    /// nothing connects, and the symptom is indistinguishable from a bad
    /// cable. The product string is what Canopy actually controls, via
    /// `set_usb_identification` in `boot.py`.
    static let circuitPythonVendorID = 0x239A

    /// A candidate wins adoption by answering a probe, not by looking right,
    /// so a `HELLO`/`PONG` timeout on the wrong port costs one of these.
    private static let probeTimeout: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.macropad", qos: .utility)

    /// Delivered on the main actor, in order. Owned by `queue` like every
    /// other mutable field here — `setOutputHandler` is the only way in,
    /// because a plain property would be written from the main actor while
    /// `emit` reads it on `queue`, and an unsynchronised read/write of a
    /// closure reference is a retain/release race, not a benign torn read.
    private var onOutput: (@MainActor @Sendable (Output) -> Void)?

    func setOutputHandler(_ handler: (@MainActor @Sendable (Output) -> Void)?) {
        queue.async { [self] in onOutput = handler }
    }

    /// Read outside `queue`, so it is the one piece of state that has to be
    /// its own synchronisation. It exists to let a quit interrupt an in-flight
    /// probe: `stop` cannot preempt `queue`, it can only wait its turn, and a
    /// probe cycle can hold the queue for `probeTimeout` per candidate.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)

    // MARK: - State owned by `queue`

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var decoder = MacroPadLineDecoder()
    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var retryDelay: TimeInterval = 1
    private var isStopped = false
    /// The active selection. Owned by `queue` like the rest of the state.
    /// Starts at `.off` so nothing is opened before `setSource` has run —
    /// `MacroPadController.start()` supplies the real value.
    private var source: MacroPadSource = .off
    /// True once hot-plug is armed. When it is false the matching callback
    /// will never fire, so the retry chain has to keep itself alive instead.
    private var hasHotplug = false

    // MARK: - Lifecycle

    func start() {
        stopRequested.withLock { $0 = false }
        queue.async { [self] in
            isStopped = false
            applySourceArming()
            attemptConnect()
        }
    }

    /// Synchronous so the caller can get the `R` as far as the kernel's tty
    /// buffer before the process exits. Not further: there is no `tcdrain`, and
    /// the `close(2)` itself is deferred to the read source's cancel handler.
    ///
    /// Deadlock is impossible — nothing on `queue` ever blocks on the main
    /// queue — but that was never the interesting risk. `queue.sync` cannot
    /// preempt work already running there, and a probe cycle blocks it for up
    /// to `probeTimeout` **per candidate**, so an uninterruptible version of
    /// this could stall Cmd+Q for seconds. `stopRequested` is set before
    /// entering the queue precisely so an in-flight probe sees it and bails.
    func stop(sendingReset: Bool) {
        stopRequested.withLock { $0 = true }
        queue.sync { [self] in
            isStopped = true
            onOutput = nil
            if sendingReset, fd >= 0, !writeBytes(MacroPadCommand.reset.wireBytes) {
                // The firmware blanks itself when the host disconnects, so a
                // failed `R` is recoverable — but it is the thing standing
                // between the user and a pad still claiming a permission
                // prompt, so it should not vanish quietly.
                logger.error("MacroPad: final reset write failed; relying on the device's own blank-on-disconnect")
            }
            closePort(notifying: false)
            disarmMatchingNotification()
        }
    }

    /// Settings selector. Switching closes the current port (blanking the pad
    /// first) so a pad that is being switched away from is not left showing
    /// stale colours — the firmware also blanks on host disconnect, so this is
    /// belt-and-braces for the case where the close is clean.
    ///
    /// Arms hot-plug only in `.local`. In `.remote` the IOKit matching
    /// notification would never fire, so `hasHotplug` stays false and the
    /// `scheduleRetry` chain is what keeps discovery alive — the same fallback
    /// that already exists for a failed arm.
    func setSource(_ newSource: MacroPadSource) {
        queue.async { [self] in
            guard source != newSource else { return }
            source = newSource
            if fd >= 0 {
                if !writeBytes(MacroPadCommand.reset.wireBytes) {
                    logger.error("MacroPad: reset write failed while switching source; the device blanks itself on disconnect")
                }
                closePort(notifying: true)
            }
            applySourceArming()
            retryDelay = 1
            attemptConnect()
        }
    }

    /// Must run on `queue`. Hot-plug is a local-USB concept only.
    private func applySourceArming() {
        if case .local = source {
            armMatchingNotification()
        } else {
            disarmMatchingNotification()
        }
    }

    func send(_ command: MacroPadCommand) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            if !writeBytes(command.wireBytes) {
                // A failed write is the main way an unplug is noticed when
                // the device wasn't mid-sentence: nothing arrives to EOF the
                // read source, so the watchdog ping is what trips this.
                logger.info("MacroPad write failed; treating as disconnect")
                closePort(notifying: true)
                scheduleRetry()
            }
        }
    }

    // MARK: - Hotplug

    private func armMatchingNotification() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("MacroPad: IONotificationPortCreate failed; falling back to periodic rescan")
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)
        notifyPort = port

        // Only `kIOMatchedNotification` is registered. Termination is detected
        // from the read/write side instead (EOF or a failed write), which has
        // to work anyway for the crash-and-yank cases a termination callback
        // wouldn't cover — a second C callback would add a path without
        // removing one.
        let context = Unmanaged.passUnretained(self).toOpaque()
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching(kIOSerialBSDServiceValue),
            { context, iterator in
                guard let context else { return }
                Unmanaged<MacroPadDevice>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handleMatched(iterator)
            },
            context,
            &iterator
        )
        guard result == KERN_SUCCESS else {
            logger.error("MacroPad: IOServiceAddMatchingNotification failed (\(result)); falling back to periodic rescan")
            IONotificationPortDestroy(port)
            notifyPort = nil
            return
        }
        matchedIterator = iterator
        hasHotplug = true
        // Draining arms the notification. The services it yields are ignored:
        // `attemptConnect` rescans the registry from scratch, so there is one
        // discovery path instead of two that can disagree.
        drain(iterator)
    }

    private func disarmMatchingNotification() {
        hasHotplug = false
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    private func handleMatched(_ iterator: io_iterator_t) {
        drain(iterator)
        guard !isStopped else { return }
        retryDelay = 1
        attemptConnect()
    }

    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // MARK: - Discovery

    private struct Candidate {
        let path: String
        /// CircuitPython exposes console on interface 0 and the data port on a
        /// higher interface. Highest-first is therefore the best guess at
        /// which of the two `/dev/cu.*` is the data port — but it is only the
        /// probe ORDER. Adoption is decided by an actual `HELLO`/`PONG`, so
        /// getting this backwards costs 1.5 s, not a broken feature.
        let interfaceNumber: Int
    }

    private func rankedCandidates() -> [Candidate] {
        var iterator: io_iterator_t = 0
        let scan = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(kIOSerialBSDServiceValue),
            &iterator
        )
        guard scan == KERN_SUCCESS else {
            // Distinguishable from "no pad plugged in", which is the whole
            // point: both produce an empty list, and only one of them is a
            // problem.
            logger.error("MacroPad: IOServiceGetMatchingServices failed (\(scan)); no candidates this pass")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [Candidate] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let path = Self.stringProperty(service, kIOCalloutDeviceKey) {
                let product = Self.searchStringProperty(service, "USB Product Name")
                let vendor = Self.searchIntProperty(service, "idVendor")
                let interface = Self.searchIntProperty(service, "bInterfaceNumber") ?? 0

                // The product string is the identifier this project actually
                // controls (`set_usb_identification` in `boot.py`); the vendor
                // is a sanity check on top of it.
                //
                // There was once a vendor-only fallback here, for the window
                // during bring-up before `set_usb_identification` had taken
                // effect. It is gone: probing means *opening* a port and
                // writing `P` to it, so a vendor-only match reaches into every
                // unrelated CircuitPython board on the machine — typing a line
                // into someone else's REPL — and the bring-up window it served
                // closed the moment the product string was confirmed on real
                // hardware.
                if product == Self.expectedProductName,
                   vendor == nil || vendor == Self.circuitPythonVendorID {
                    candidates.append(Candidate(path: path, interfaceNumber: interface))
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return candidates.sorted { $0.interfaceNumber > $1.interfaceNumber }
    }

    /// The single list `attemptConnect` walks, whichever mode is active.
    private func rankedEndpoints() -> [Endpoint] {
        switch source {
        case .off:
            return []
        case .remote(let endpoint):
            return [.tcp(endpoint)]
        case .local:
            return rankedCandidates().map { .serial(path: $0.path, interfaceNumber: $0.interfaceNumber) }
        }
    }

    private static func stringProperty(_ entry: io_object_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func searchProperty(_ entry: io_object_t, _ key: String) -> CFTypeRef? {
        IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }

    private static func searchStringProperty(_ entry: io_object_t, _ key: String) -> String? {
        searchProperty(entry, key) as? String
    }

    private static func searchIntProperty(_ entry: io_object_t, _ key: String) -> Int? {
        (searchProperty(entry, key) as? NSNumber)?.intValue
    }

    // MARK: - Connect

    private func attemptConnect() {
        guard !isStopped, !source.isOff, fd < 0 else { return }
        let endpoints = rankedEndpoints()
        guard !endpoints.isEmpty else {
            // Nothing enumerated. With hot-plug armed the matching callback is
            // the wake-up and a timer would be redundant — but when arming
            // failed, this is the only thread back, and returning here would
            // end discovery for the lifetime of the process while the log
            // claimed a fallback existed.
            if !hasHotplug { scheduleRetry() }
            return
        }

        // Not `for … where`: `openAndProbe` opens a port, writes to it, and
        // can block for `probeTimeout`. That does not belong in a filter.
        for endpoint in endpoints {
            if openAndProbe(endpoint) { return }
        }
        // Every candidate stayed silent. Common during bring-up (wrong port,
        // firmware not running) and after a reset that is still booting.
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !isStopped, !source.isOff else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        queue.asyncAfter(deadline: .now() + delay) { [self] in attemptConnect() }
    }

    /// Opens the port, asks it to identify itself, and adopts it only if it
    /// answers. Probing rather than trusting the ranking is what makes the
    /// console-vs-data ordering a preference rather than a dependency.
    private func openAndProbe(_ endpoint: Endpoint) -> Bool {
        let handle: Int32
        switch endpoint {
        case .serial(let path, _):
            let opened = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard opened >= 0 else {
                // `EBUSY` here is the single most common bring-up state — a
                // `screen` session, a CircuitPython IDE, or (with the remote
                // transport) the bridge on this same machine holding the port
                // — and it is unactionable unless it is said out loud.
                logger.notice("""
                    MacroPad: open(\(path, privacy: .public)) failed: \
                    \(String(cString: strerror(errno)), privacy: .public)
                    """)
                return false
            }
            // macOS does NOT make /dev/cu.* exclusive by default — measured: a
            // second open() succeeds while Canopy already holds the port.
            // Exclusivity is opt-in, and without it the bridge's socat can open
            // the same pad this Canopy is driving, splitting the key-event
            // stream between two readers and interleaving two writers' colour
            // commands. A failure here is worth saying out loud but not worth
            // refusing the port over: a shared pad still works, it just cannot
            // detect the collision.
            if ioctl(opened, TIOCEXCL) != 0 {
                logger.notice("""
                    MacroPad: TIOCEXCL on \(path, privacy: .public) failed: \
                    \(String(cString: strerror(errno)), privacy: .public); \
                    another process can still open this pad
                    """)
            }
            guard configureTTY(opened) else {
                close(opened)
                return false
            }
            handle = opened
        case .tcp(let remote):
            guard let opened = openTCP(remote) else { return false }
            handle = opened
        }

        decoder.reset()
        // The device sends `HELLO` unprompted when the data port opens, so
        // this ping is belt-and-braces for the case where we opened during
        // that window and missed it. If it can't even be written, the port is
        // not viable and waiting out the full timeout learns nothing.
        guard writeBytes(MacroPadCommand.ping.wireBytes, to: handle) else {
            logger.notice("MacroPad: ping write failed on \(endpoint.label, privacy: .public); skipping candidate")
            close(handle)
            return false
        }

        let deadline = Date().addingTimeInterval(Self.probeTimeout)
        var buffer = [UInt8](repeating: 0, count: 512)
        var pending: [MacroPadEvent] = []

        while Date() < deadline {
            // A quit issued mid-probe would otherwise wait out the full cycle
            // behind `stop`'s `queue.sync`.
            if stopRequested.withLock({ $0 }) { break }
            var poller = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let ready = poll(&poller, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            let count = buffer.withUnsafeMutableBytes { read(handle, $0.baseAddress, $0.count) }
            if count <= 0 {
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                break
            }
            pending.append(contentsOf: decoder.feed(Data(buffer[0..<count])))
            let identified = pending.contains {
                if case .hello = $0 { return true }
                if case .pong = $0 { return true }
                return false
            }
            if identified {
                adopt(handle: handle, label: endpoint.label, pending: pending)
                return true
            }
        }

        close(handle)
        decoder.reset()
        return false
    }

    private func configureTTY(_ handle: Int32) -> Bool {
        var settings = termios()
        guard tcgetattr(handle, &settings) == 0 else {
            logger.error("MacroPad: tcgetattr failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        cfmakeraw(&settings)
        // CDC-ACM ignores the line rate, but the fields still have to be
        // plausible for `tcsetattr` to accept them.
        cfsetspeed(&settings, speed_t(B115200))
        settings.c_cc.16 = 0 // VMIN — reads are driven by the dispatch source
        settings.c_cc.17 = 0 // VTIME
        guard tcsetattr(handle, TCSANOW, &settings) == 0 else {
            // This failing is the "CDC-ACM ignores the line rate, but the
            // fields still have to be plausible" assumption above turning out
            // to be wrong — worth hearing about rather than presenting as a
            // pad that just won't connect.
            logger.error("MacroPad: tcsetattr failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        return true
    }

    /// Connects to a bridge over TCP and returns a probe-ready descriptor.
    ///
    /// The result is deliberately indistinguishable from a serial fd to
    /// everything downstream: the same `HELLO`/`PONG` probe adopts it, the
    /// same read source drives it, the same `writeBytes` feeds it. No
    /// `configureTTY` — there is no line discipline on a socket.
    ///
    /// Known bound: `getaddrinfo` blocks, and it runs on `queue`, which
    /// `stop()` waits on with `queue.sync`. A hung DNS lookup therefore
    /// lengthens Cmd+Q. Tailscale MagicDNS resolves locally and fails fast, so
    /// this is accepted; if it is ever observed the fix is to move resolution
    /// off the synchronous path, not to shorten a timeout.
    private func openTCP(_ endpoint: MacroPadRemoteEndpoint) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        // The port is already a number; without this the resolver would also
        // consult /etc/services for it.
        hints.ai_flags = AI_NUMERICSERV

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &list)
        guard status == 0, let head = list else {
            // Distinguishable from a refused connection, which is the whole
            // point: a typo'd host and a bridge that isn't running are
            // different problems with different fixes.
            logger.notice("""
                MacroPad: getaddrinfo(\(endpoint.displayLabel, privacy: .public)) failed: \
                \(String(cString: gai_strerror(status)), privacy: .public)
                """)
            return nil
        }
        defer { freeaddrinfo(head) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let info = node {
            // A quit issued mid-connect would otherwise wait out the full
            // timeout for every address the resolver returned.
            if stopRequested.withLock({ $0 }) { return nil }
            if let handle = connectSocket(info.pointee, label: endpoint.displayLabel) { return handle }
            node = info.pointee.ai_next
        }
        return nil
    }

    /// One address, one attempt. Returns a connected non-blocking descriptor
    /// or nil, having closed anything it opened.
    private func connectSocket(_ info: addrinfo, label: String) -> Int32? {
        let handle = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard handle >= 0 else { return nil }

        var enable: Int32 = 1
        // NOT optional. A write to a hung-up tty returns EIO; a write to a
        // closed socket raises SIGPIPE, which has no handler here and takes
        // the whole app down. Stopping the bridge would crash Canopy.
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        // Commands are ~10 bytes. Nagle would hold a colour change behind the
        // previous ACK.
        setsockopt(handle, IPPROTO_TCP, TCP_NODELAY, &enable, socklen_t(MemoryLayout<Int32>.size))
        // Closing the bridge Mac's lid leaves the connection half-open, and
        // writes keep succeeding into the send buffer — so neither the read
        // side nor the controller's watchdog ping can notice. 15s idle, 15s
        // between probes, 3 probes: ~45s, the same budget SSH remote uses
        // (ServerAliveInterval=15, ServerAliveCountMax=3).
        setsockopt(handle, SOL_SOCKET, SO_KEEPALIVE, &enable, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 15
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        var interval: Int32 = 15
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
        var probes: Int32 = 3
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPCNT, &probes, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking for the same reason the serial path opens O_NONBLOCK:
        // it is what lets `writeBytes`'s EAGAIN loop and the read source work
        // unchanged on this descriptor.
        let flags = fcntl(handle, F_GETFL, 0)
        guard flags >= 0, fcntl(handle, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(handle)
            return nil
        }

        if connect(handle, info.ai_addr, info.ai_addrlen) == 0 { return handle }
        guard errno == EINPROGRESS else {
            logger.notice("""
                MacroPad: connect(\(label, privacy: .public)) failed: \
                \(String(cString: strerror(errno)), privacy: .public)
                """)
            close(handle)
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.probeTimeout)
        while Date() < deadline {
            if stopRequested.withLock({ $0 }) { break }
            var poller = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let ready = poll(&poller, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(handle, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { break }
            if socketError == 0 { return handle }
            logger.notice("""
                MacroPad: connect(\(label, privacy: .public)) failed: \
                \(String(cString: strerror(socketError)), privacy: .public)
                """)
            close(handle)
            return nil
        }

        logger.notice("MacroPad: connect(\(label, privacy: .public)) timed out")
        close(handle)
        return nil
    }

    /// Events decoded during the probe window are forwarded after
    /// `.connected`, deliberately: a `HELLO` almost always lands there, and
    /// dropping it would mean the first thing the controller learns about the
    /// pad is nothing. A key pressed *during* the probe lands here too and
    /// will focus that pane — real input, treated as such. A key already held
    /// when the cable goes in does not: the firmware adopts that state
    /// silently rather than inventing a press.
    private func adopt(handle: Int32, label: String, pending: [MacroPadEvent]) {
        fd = handle
        retryDelay = 1

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(handle) }
        readSource = source
        source.resume()

        logger.info("MacroPad connected on \(label, privacy: .public)")
        emit(.connected(path: label))
        for event in pending { emit(.event(event)) }
    }

    // MARK: - I/O

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // A pulled cable and a driver fault both end up here and are
            // different diagnoses; one string for both makes "it disconnects
            // every few minutes" unanswerable from a log.
            if count == 0 {
                logger.info("MacroPad: EOF on read; device disconnected")
            } else {
                logger.error("MacroPad: read failed: \(String(cString: strerror(errno)), privacy: .public)")
            }
            closePort(notifying: true)
            scheduleRetry()
            return
        }
        for event in decoder.feed(Data(buffer[0..<count])) {
            emit(.event(event))
        }
    }

    @discardableResult
    private func writeBytes(_ data: Data, to handle: Int32? = nil) -> Bool {
        let target = handle ?? fd
        guard target >= 0 else { return false }
        var offset = 0
        // Bounded so a wedged port can't park the queue: the longest legal
        // command is well under one pipe buffer, so needing more than a few
        // retries means the port is gone, not busy.
        var attemptsLeft = 20
        return data.withUnsafeBytes { raw -> Bool in
            // An empty command is a bug, not a no-op: this function's `false`
            // is the system's disconnect detector, so reporting success for a
            // write that never happened would hide it.
            guard let base = raw.baseAddress, raw.count > 0 else {
                logger.error("MacroPad: refusing to write an empty command")
                return false
            }
            while offset < raw.count {
                let written = write(target, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                // `errno` only means anything after -1; consulting it on a 0
                // return reads whatever the last failing syscall left there.
                guard written < 0 else {
                    logger.error("MacroPad: write returned 0")
                    return false
                }
                if errno == EAGAIN || errno == EINTR {
                    attemptsLeft -= 1
                    guard attemptsLeft > 0 else { return false }
                    usleep(2000)
                    continue
                }
                return false
            }
            return true
        }
    }

    private func closePort(notifying: Bool) {
        guard fd >= 0 else { return }
        // The cancel handler owns the `close(2)`; closing here as well would
        // race it onto a descriptor number the system may have reissued.
        readSource?.cancel()
        readSource = nil
        fd = -1
        decoder.reset()
        if notifying { emit(.disconnected) }
    }

    private func emit(_ output: Output) {
        guard let onOutput else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onOutput(output) }
        }
    }
}
