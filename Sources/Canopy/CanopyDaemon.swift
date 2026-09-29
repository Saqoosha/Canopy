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

private nonisolated(unsafe) var terminationSource: DispatchSourceSignal?

/// Routes launchd's SIGTERM to `NSApp.terminate`; left at its default it ends
/// the process without `applicationWillTerminate`, leaving the socket file behind.
private nonisolated func installTerminationHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    terminationSource = source
}

@MainActor
final class DaemonDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var server: MirrorServer?
    private var reaper: DaemonReaper?
    private var config = DaemonConfig.defaults
    private var configModified: Date?
    private var configTimer: Timer?
    /// The TCP port the listener is on, or being brought up on; nil when off.
    private var tcpPort: UInt16?

    private var settingsFile: URL { CanopySettings.shared.filePath }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("daemon starting pid=\(getpid())")
        Task { await store.refreshRecents() }

        let server = MirrorServer(store: store, token: MirrorAccess.token(createIfMissing: false) ?? "")
        server.acceptsControl = true
        server.refreshesToken = true
        server.bypassAllowed = { [weak self] in self?.config.allowBypass ?? false }
        // Exiting non-zero lets launchd (KeepAlive SuccessfulExit=false) start a fresh daemon.
        server.onLocalFailure = { exit(1) }
        self.server = server
        // Exit 0 only for "another daemon serves it", which launchd must not restart;
        // any other failure exits 1 so it gets another try.
        if DaemonPaths.socketIsLive(path: DaemonPaths.current) {
            logger.error("another daemon serves the local socket; exiting")
            FileHandle.standardError.write(Data("canopy daemon: already running\n".utf8))
            exit(0)
        }
        guard server.startLocal(socketPath: DaemonPaths.current) else {
            logger.error("daemon cannot open the local socket; exiting")
            FileHandle.standardError.write(Data("canopy daemon: local socket unavailable\n".utf8))
            exit(1)
        }
        reloadConfig()
        // The GUI changes these settings in another process; follow them.
        configTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }

        let reaper = DaemonReaper(store: store)
        self.reaper = reaper
        reaper.start()
    }

    private func reloadConfig() {
        // A password reset in the GUI must also end connections that are already open.
        if tcpPort != nil { server?.refreshToken() }
        let modified = (try? FileManager.default.attributesOfItem(atPath: settingsFile.path))?[.modificationDate] as? Date
        guard server != nil, configModified == nil || modified != configModified else { return }
        guard let parsed = DaemonConfig.parse(try? Data(contentsOf: settingsFile)) else { return }
        configModified = modified ?? Date.distantPast
        config = parsed
        applyTCP()
    }

    /// Opens, moves or closes the Tailscale listener to match `config`.
    private func applyTCP() {
        guard let server else { return }
        var wanted = DaemonPaths.tcpPort(mirrorEnabled: config.mirrorEnabled, basePort: config.daemonPort,
                                         bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        // No password means every TCP client would be refused; do not listen at all.
        if wanted != nil, MirrorAccess.token(createIfMissing: true) == nil {
            logger.error("no mirror password; Tailscale listener stays closed")
            wanted = nil
        }
        guard wanted != tcpPort else { return }
        tcpPort = wanted
        guard let wanted else {
            logger.notice("Mirror is off; Tailscale listener closed")
            server.stopTCP()
            return
        }
        startTCP(server, port: wanted)
    }

    /// Tailscale may come up after login; retry until it has an address.
    private func startTCP(_ server: MirrorServer, port: UInt16) {
        guard tcpPort == port else { return }
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
        configTimer?.invalidate()
        reaper?.stop()
        server?.stopTCP()
        server?.stopLocal()
        for session in store.openSessions { session.shim?.stop() }
    }
}
