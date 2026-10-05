import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorRelay")

/// `Canopy --mirror-relay <host> <port> <socket>`: accepts the daemon's Tailscale port on its
/// behalf while an app update waits for the daemon to restart, and copies bytes to and from
/// the daemon's relay socket.
///
/// Why it exists: an update replaces the bundle under the running daemon, and from then on
/// macOS's Application Firewall cannot resolve that process's path (`proc_pidpath` fails with
/// ENOENT; socketfilterfw logs "processPath is still nil … Performing default drop action"), and
/// every inbound flow is dropped (with stealth mode on, the client sees only SYN retransmits)
/// until the daemon restarts, which it defers while anything would be lost.
/// This process is started from the binary now on disk, whose path resolves, so its flows match
/// the app's firewall rule. Measured 2026-10-05 against build 157 → 158.
///
/// It holds no state and checks nothing: the daemon serves the relay socket as an untrusted
/// peer, so passwords and the bypass gate apply as they do on TCP. A Mac client loses
/// `openRedirectHost`, since its peer is a Unix socket.
enum MirrorRelay {
    static let flag = "--mirror-relay"

    struct Arguments: Equatable {
        let host: String
        let port: UInt16
        let socketPath: String
    }

    /// The argv after the executable. Kept stable across builds: an old daemon starts a newer binary.
    static func arguments(_ args: Arguments) -> [String] {
        [flag, args.host, String(args.port), args.socketPath]
    }

    /// Reads `arguments(_:)` back out of a full `CommandLine.arguments`.
    static func parse(_ argv: [String]) -> Arguments? {
        guard let index = argv.firstIndex(of: flag), argv.count >= index + 4,
              let port = UInt16(argv[index + 2]), port > 0,
              !argv[index + 1].isEmpty, !argv[index + 3].isEmpty,
              // Past `sun_path` Network traps (153 bytes measured: exit 133).
              argv[index + 3].utf8.count <= DaemonPaths.maxSocketPathBytes else { return nil }
        return Arguments(host: argv[index + 1], port: port, socketPath: argv[index + 3])
    }

    /// Whether `onDisk` can be trusted to know `flag`: builds from before the relay would start
    /// the whole app instead, so a downgrade gets no relay.
    static func installedBuildKnowsRelay(onDisk: String, launched: String?) -> Bool {
        guard let onDisk = Int(onDisk), let launched = launched.flatMap(Int.init) else { return false }
        return onDisk >= launched
    }

    /// Bind attempts before giving up; the daemon's listener may still be closing.
    static let bindAttempts = 10

    static func run(argv: [String]) -> Never {
        guard let args = parse(argv) else {
            logger.error("relay refused its arguments: \(argv.dropFirst().joined(separator: " "), privacy: .public)")
            exit(2)
        }
        // The daemon holds the write end of stdin; EOF means it is gone or stopped this relay.
        Thread.detachNewThread {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            logger.notice("stdin closed; relay exiting")
            exit(0)
        }
        let relay = Relay(args: args)
        relay.listen(attempt: 1)
        // Its handlers hold it weakly; an optimised build would otherwise free it here.
        withExtendedLifetime(relay) { dispatchMain() }
    }
}

private final class Relay: @unchecked Sendable {
    private let args: MirrorRelay.Arguments
    private let queue = DispatchQueue(label: "sh.saqoo.Canopy.MirrorRelay")
    private var listener: NWListener?

    init(args: MirrorRelay.Arguments) {
        self.args = args
    }

    func listen(attempt: Int) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(args.host),
                                                     port: NWEndpoint.Port(rawValue: args.port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("relay cannot create a listener: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
        self.listener = listener
        let host = args.host, port = args.port
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.notice("relay listening on \(host, privacy: .public):\(port)")
            case .waiting(let error), .failed(let error):
                listener.cancel()
                guard attempt < MirrorRelay.bindAttempts else {
                    logger.error("relay cannot bind \(host, privacy: .public):\(port): \(error.localizedDescription, privacy: .public)")
                    exit(1)
                }
                self?.queue.asyncAfter(deadline: .now() + 0.5) { self?.listen(attempt: attempt + 1) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let outbound = NWConnection(to: .unix(path: self.args.socketPath), using: .tcp)
            RelayPair(inbound: inbound, outbound: outbound, queue: self.queue).start()
        }
        listener.start(queue: queue)
    }
}

/// One client: bytes in each direction. Each receive waits for the
/// previous send to be processed, so a slow side holds the other back instead of buffering.
/// An EOF is passed on as one (a half-close), and the pair closes once both directions ended.
private final class RelayPair: @unchecked Sendable {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    private var directionsOpen = 2

    init(inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue) {
        self.inbound = inbound
        self.outbound = outbound
        self.queue = queue
    }

    func start() {
        // The pair keeps itself alive through these handlers until `close` clears them. A side that
        // fails is left to the pumps: closing here raced the last bytes the daemon sent before it
        // hung up (an `attach_error`), and the client saw nothing. `.waiting` is a socket nobody
        // accepts on, which no receive would ever report.
        for connection in [inbound, outbound] {
            connection.stateUpdateHandler = { state in
                if case .waiting = state { self.close() }
            }
            connection.start(queue: queue)
        }
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            let payload = data.flatMap { $0.isEmpty ? nil : $0 }
            if error != nil, payload == nil {
                self.close()
                return
            }
            let isComplete = isComplete || error != nil
            guard payload != nil || isComplete else {
                self.pump(from: source, to: sink)
                return
            }
            sink.send(content: payload, contentContext: isComplete ? .finalMessage : .defaultMessage,
                      isComplete: isComplete, completion: .contentProcessed { sendError in
                if sendError != nil {
                    self.close()
                } else if isComplete {
                    self.directionEnded()
                } else {
                    self.pump(from: source, to: sink)
                }
            })
        }
    }

    private func directionEnded() {
        directionsOpen -= 1
        if directionsOpen == 0 { close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        for connection in [inbound, outbound] {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}

/// The daemon's handle on a running relay child.
@MainActor
final class MirrorRelayProcess {
    private var process: Process?
    private var stdin: Pipe?
    private(set) var address: (host: String, port: UInt16)?
    /// The build on disk when this relay was started; a later update replaces its binary too.
    private(set) var build: String?

    var isRunning: Bool { process?.isRunning == true }

    /// Starts `executable` as a relay; false when it could not be launched.
    func start(executable: URL, args: MirrorRelay.Arguments, build: String) -> Bool {
        stop()
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = MirrorRelay.arguments(args)
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = Self.logExit
        do {
            try proc.run()
        } catch {
            logger.error("relay launch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.notice("relay pid \(proc.processIdentifier) started from the installed build for \(args.host, privacy: .public):\(args.port)")
        process = proc
        stdin = pipe
        address = (args.host, args.port)
        self.build = build
        return true
    }

    /// Written outside the main actor: the handler runs on a Foundation thread.
    nonisolated private static func logExit(_ proc: Process) {
        logger.notice("relay pid \(proc.processIdentifier) exited \(proc.terminationStatus)")
    }

    /// Ends the relay and waits briefly, so whatever binds next finds the port free.
    func stop() {
        guard let proc = process else { return }
        process = nil
        address = nil
        build = nil
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        if proc.isRunning { proc.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
}
