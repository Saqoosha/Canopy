import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopyDaemon")

/// `Canopy --daemon`: an accessory app with no windows that owns sessions and
/// serves them over its local socket and Tailscale. See
/// docs/superpowers/specs/2026-09-29-canopy-server-design.md.
@MainActor
enum CanopyDaemon {
    private static var delegate: DaemonDelegate?

    static func run() {
        #if DEBUG
        // The probe belongs to the GUI entry; a daemon must never start under it.
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] != "1" else { exit(0) }
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installTerminationHandler()
        let delegate = DaemonDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// launchd stops the agent with SIGTERM, whose default action ends the
/// process without `applicationWillTerminate` — measured: the socket file was
/// left behind. Routing it to `NSApp.terminate` runs the orderly shutdown.
/// `nonisolated` and outside every `@MainActor` type on purpose: a
/// `DispatchSource` handler is a plain block, and a closure literal written in
/// a main-actor context aborts when the source fires (CLAUDE.md, the
/// `PeerNameStore.makeWatcher` entry).
private nonisolated(unsafe) var terminationSource: DispatchSourceSignal?

private nonisolated func installTerminationHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }
    source.resume()
    terminationSource = source
}

@MainActor
final class DaemonDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var server: MirrorServer?
    private var reaper: DaemonReaper?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("daemon starting pid=\(getpid())")
        Task { await store.refreshRecents() }
        KeepAliveCoordinator.shared.start()

        let settings = CanopySettings.shared
        let tcpPort = DaemonPaths.tcpPort(mirrorEnabled: settings.mirrorEnabled, basePort: settings.daemonPort,
                                          bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        // The password is only minted for a TCP listener; the local socket needs none.
        let token = tcpPort.flatMap { _ in MirrorAccess.token(createIfMissing: true) } ?? ""
        let server = MirrorServer(store: store, token: token)
        self.server = server
        guard server.startLocal(socketPath: DaemonPaths.current) else {
            // Another daemon of this build owns the socket and its sessions; a second one has nothing to serve.
            logger.error("daemon already running; exiting")
            exit(0)
        }
        if let tcpPort { startTCP(server, port: tcpPort) } else { logger.notice("Mirror is off; no Tailscale listener") }

        let reaper = DaemonReaper(store: store)
        self.reaper = reaper
        reaper.start()
    }

    /// Tailscale may come up after login; retry until it has an address.
    private func startTCP(_ server: MirrorServer, port: UInt16) {
        guard let host = MirrorAccess.tailscaleIPv4() else {
            logger.notice("no Tailscale address yet; retrying in 30 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated { self?.startTCP(server, port: port) }
            }
            return
        }
        server.start(host: host, port: port)
    }

    func applicationWillTerminate(_ notification: Notification) {
        reaper?.stop()
        server?.stop()
        server?.stopLocal()
        for session in store.openSessions { session.shim?.stop() }
    }
}
