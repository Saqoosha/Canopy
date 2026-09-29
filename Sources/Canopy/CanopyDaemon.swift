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
        // Before anything touches `CanopySettings.shared`: the file is the GUI's.
        CanopySettings.persistsChanges = false
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        RosterPublisher.relayAllowedInProcess = RosterPublisher.relayAllowed(
            isDaemon: true, isDebug: isDebug, env: ProcessInfo.processInfo.environment)
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
    private var rosterPublisher: RosterPublisher?
    private var config = DaemonConfig.defaults
    private var configModified: Date?
    private var unreadableModified: Date?
    private var usageTimer: Timer?
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

        // No panes here: the sessions worth keeping warm are the ones a client is attached to.
        KeepAliveCoordinator.shared.targets = { store in
            KeepAliveCoordinator.daemonTargets(store.openSessions).map { ("session \($0.resumeId.prefix(8))", $0) }
        }
        KeepAliveCoordinator.shared.start()

        let reaper = DaemonReaper(store: store)
        self.reaper = reaper
        reaper.start()

        // The phone's view of this Mac: the sessions live here now, so the roster does too.
        if RosterPublisher.relayAllowedInProcess {
            let publisher = RosterPublisher(store: store, settings: CanopySettings.shared)
            rosterPublisher = publisher
            publisher.start()
            RosterRouting.install(on: publisher, store: store)
            // Usage on the roster before any shim fetches it, and kept current while none does:
            // only with the roster on, and not when a shim asked within the last few minutes
            // (the endpoint allows about one request a minute per account).
            Task { await ClaudeUsageDirect.refreshLocalAccount() }
            usageTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
                Task { @MainActor in
                    guard CanopySettings.shared.rosterEnabled,
                          !SharedRateLimitData.shared.local.requestedWithin(5 * 60) else { return }
                    await ClaudeUsageDirect.refreshLocalAccount()
                }
            }
        } else {
            logger.notice("roster: not published by a Debug daemon (set CANOPY_DAEMON_ROSTER=1 to allow)")
        }
    }

    private func reloadConfig() {
        // A password reset in the GUI must also end connections that are already open.
        if tcpPort != nil { server?.refreshToken() }
        superviseListener()
        let modified = (try? FileManager.default.attributesOfItem(atPath: settingsFile.path))?[.modificationDate] as? Date
        guard server != nil, configModified == nil || modified != configModified else { return }
        // One read for both, so the two cannot see different writes.
        let data = try? Data(contentsOf: settingsFile)
        guard let parsed = DaemonConfig.parse(data) else {
            // Usually a read that landed mid-write, which the next tick heals; logged once per
            // version in case it is a hand edit that broke the file and freezes every setting.
            if modified != unreadableModified {
                unreadableModified = modified
                logger.notice("settings.json is unreadable; keeping the settings the daemon had")
            }
            return
        }
        configModified = modified ?? Date.distantPast
        config = parsed
        // Roster, keep-alive and recap toggles the GUI changed; read only, never written back.
        if let data, let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            CanopySettings.shared.reload(from: dict)
        }
        applyTCP()
    }

    /// Opens, moves or closes the Tailscale listener to match `config`.
    private func applyTCP() {
        guard let server else { return }
        var wanted = DaemonPaths.tcpPort(mirrorEnabled: config.mirrorEnabled, basePort: config.port,
                                         bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        // No password means every TCP client would be refused; do not listen at all.
        if wanted != nil, MirrorAccess.token(createIfMissing: true) == nil {
            logger.error("no mirror password; Tailscale listener stays closed")
            wanted = nil
            // Before the guard: at launch `tcpPort` is already nil, and Settings must still say why.
            MirrorServerStatus.shared.state = .noPassword
        } else if wanted == nil {
            MirrorServerStatus.shared.state = .off
        }
        guard wanted != tcpPort else { return }
        tcpPort = wanted
        guard wanted != nil else {
            logger.notice("Mirror is off or has no password; Tailscale listener closed")
            server.stopTCP()
            return
        }
        lastListenAttempt = nil
        superviseListener()
    }

    /// When the listener last tried to bind; nil to try at once.
    private var lastListenAttempt: Date?
    private var loggedNoTailscale = false

    /// Keeps the Tailscale listener up: binds once Tailscale has an address, rebinds when that
    /// address changes, and retries a failed bind. Runs on every config tick; the daemon is the
    /// only listener other Macs and the phone can reach.
    private func superviseListener() {
        guard let server, let port = tcpPort else { return }
        let host = MirrorAccess.tailscaleIPv4()
        let since = lastListenAttempt.map { Date().timeIntervalSince($0) }
        switch Self.listenerAction(tailscaleHost: host, boundHost: server.boundAddress?.host,
                                   binding: server.pendingAddress != nil, secondsSinceAttempt: since) {
        case .keep:
            break
        case .waitForTailscale:
            if !loggedNoTailscale {
                loggedNoTailscale = true
                logger.notice("no Tailscale address; the listener waits for one")
            }
            if server.boundAddress != nil { server.stopTCP() }
            MirrorServerStatus.shared.state = .noTailscale
        case .start(let host):
            loggedNoTailscale = false
            lastListenAttempt = Date()
            logger.notice("binding the Tailscale listener on \(host, privacy: .public):\(port)")
            server.start(host: host, port: port)
        }
    }

    nonisolated enum ListenerAction: Equatable { case keep, waitForTailscale, start(host: String) }

    /// How often a failed bind is retried.
    nonisolated static let listenRetryInterval: TimeInterval = 30

    /// What to do with a wanted listener this tick. A moved address rebinds at once; a
    /// listener that never bound, or failed, retries every `listenRetryInterval`.
    nonisolated static func listenerAction(tailscaleHost: String?, boundHost: String?, binding: Bool,
                                           secondsSinceAttempt: TimeInterval?) -> ListenerAction {
        guard let tailscaleHost else { return .waitForTailscale }
        if binding || boundHost == tailscaleHost { return .keep }
        if boundHost != nil { return .start(host: tailscaleHost) }
        if let since = secondsSinceAttempt, since < listenRetryInterval { return .keep }
        return .start(host: tailscaleHost)
    }

    func applicationWillTerminate(_ notification: Notification) {
        configTimer?.invalidate()
        usageTimer?.invalidate()
        reaper?.stop()
        // Asks for a clean close; the process may exit before the frame is flushed.
        rosterPublisher?.stop()
        server?.stopTCP()
        server?.stopLocal()
        for session in store.openSessions { session.shim?.stop() }
    }
}
