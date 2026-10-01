import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopyDaemon")

/// `Canopy --daemon`: a process with no NSApplication that owns sessions and
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
        // Captured now, before an update can replace the bundle under this process.
        _ = DaemonUpgrade.launchedBuild
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        RosterPublisher.relayAllowedInProcess = RosterPublisher.relayAllowed(
            isDaemon: true, isDebug: isDebug, env: ProcessInfo.processInfo.environment)
        // No NSApplication: one would register this process with LaunchServices as a second
        // instance of the app, which the Dock, Sparkle and `open` then treat as Canopy itself (#279).
        let delegate = DaemonDelegate()
        self.delegate = delegate
        installTerminationHandler(delegate)
        delegate.start()
        // RunLoop, not dispatchMain(): the daemon's timers are scheduled on it. A pass ends after a
        // source or main-queue block, not after a timer, so a timer's autoreleases wait for the next one.
        while true {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
        }
    }
}

private nonisolated(unsafe) var terminationSource: DispatchSourceSignal?

/// launchd's SIGTERM stops the sessions and removes the socket file; left at its default it ends
/// the process with the socket file behind.
private nonisolated func installTerminationHandler(_ delegate: DaemonDelegate) {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { [weak delegate] in
        MainActor.assumeIsolated {
            delegate?.shutDown()
            exit(0)
        }
    }
    source.resume()
    terminationSource = source
}

@MainActor
final class DaemonDelegate {
    private let store = SessionStore()
    private var server: MirrorServer?
    private var reaper: DaemonReaper?
    private var rosterPublisher: RosterPublisher?
    private var config = DaemonConfig.defaults
    private var configModified: Date?
    private var unreadableModified: Date?
    private var usageTimer: Timer?
    private var upgradeTimer: Timer?
    private var previousOnDiskBuild: String?
    private var lastUpgradeHold: String?

    /// An app update replaced the binary under this process: tell attached panes, stop the
    /// sessions cleanly and exit non-zero so launchd starts the new build. Panes that got the
    /// notice re-attach and resume; anything else sees an ordinary drop.
    private func restartIfUpgraded() {
        let onDisk = DaemonUpgrade.onDiskBuild()
        defer { previousOnDiskBuild = onDisk }
        guard let onDisk, onDisk != DaemonUpgrade.launchedBuild else { return }
        let underLaunchd = DaemonUpgrade.isUnderLaunchd(env: ProcessInfo.processInfo.environment,
                                                        bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy")
        let blocker = store.openSessions.lazy.compactMap { session in
            session.shim?.upgradeBlocker.map { "\(session.resumeId.prefix(8)): \($0)" }
        }.first
        guard DaemonUpgrade.shouldRestart(launchedBuild: DaemonUpgrade.launchedBuild, onDiskBuild: onDisk,
                                          previousOnDiskBuild: previousOnDiskBuild,
                                          underLaunchd: underLaunchd, blocked: blocker != nil) else {
            let hold = !underLaunchd ? "not started by launchd, so nothing would start the new build"
                : blocker ?? "confirming on the next check"
            if hold != lastUpgradeHold {
                lastUpgradeHold = hold
                logger.notice("build \(onDisk, privacy: .public) is installed (running \(DaemonUpgrade.launchedBuild ?? "?", privacy: .public)); waiting: \(hold, privacy: .public)")
            }
            return
        }
        logger.notice("restarting for build \(onDisk, privacy: .public) (running \(DaemonUpgrade.launchedBuild ?? "?", privacy: .public))")
        upgradeTimer?.invalidate()
        configTimer?.invalidate()  // a reload in the next second would re-open the listeners
        server?.announceRestart()
        // Sends are asynchronous: give the notice a moment to leave before the process does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.shutDown()
                exit(1)
            }
        }
    }
    private var configTimer: Timer?
    /// The TCP port the listener is on, or being brought up on; nil when off.
    private var tcpPort: UInt16?

    private var settingsFile: URL { CanopySettings.shared.filePath }

    func start() {
        logger.notice("daemon starting pid=\(getpid())")
        Task { await store.refreshRecents() }

        let server = MirrorServer(store: store, token: MirrorAccess.token(createIfMissing: false) ?? "")
        server.acceptsControl = true
        server.refreshesToken = true
        server.bypassAllowed = { [weak self] in self?.config.allowBypass ?? false }
        // Exiting non-zero lets launchd (KeepAlive SuccessfulExit=false) start a fresh daemon.
        server.onLocalFailure = { [weak self] in
            self?.shutDown()
            exit(1)
        }
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

        upgradeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfUpgraded() }
        }

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
        // A file that exists but cannot be read is not a missing one (which means defaults).
        guard modified == nil || data != nil, let parsed = DaemonConfig.parse(data) else {
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
        missingTailscaleTicks = host == nil ? missingTailscaleTicks + 1 : 0
        if server.boundAddress != nil { failedBinds = 0 }
        let since = lastListenAttempt.map { Date().timeIntervalSince($0) }
        let bound = server.boundAddress.map { "\($0.host):\($0.port)" }
        let pending = server.pendingAddress.map { "\($0.host):\($0.port)" }
        switch Self.listenerAction(want: host.map { "\($0):\(port)" }, bound: bound, pending: pending,
                                   secondsSinceAttempt: since, retryAfter: Self.retryDelay(failedBinds: failedBinds)) {
        case .keep:
            break
        case .waitForTailscale:
            // A reconnect or wake can hide the address for a moment; only a gap that lasts
            // `tailscaleGraceTicks` ticks ends the connections a bound listener holds.
            guard missingTailscaleTicks >= Self.tailscaleGraceTicks else { break }
            if !loggedNoTailscale {
                loggedNoTailscale = true
                logger.notice("no Tailscale address; the listener waits for one")
            }
            if server.boundAddress != nil || server.pendingAddress != nil { server.stopTCP() }
            MirrorServerStatus.shared.state = .noTailscale
        case .start:
            guard let host else { break }
            loggedNoTailscale = false
            if lastListenAttempt != nil, server.boundAddress == nil { failedBinds += 1 }
            lastListenAttempt = Date()
            // Once per failure streak: a busy port retries for as long as it stays busy.
            if failedBinds <= 1 {
                logger.notice("binding the Tailscale listener on \(host, privacy: .public):\(port)")
            }
            server.start(host: host, port: port)
        }
    }

    private var missingTailscaleTicks = 0
    private var failedBinds = 0

    /// Ticks (5 s each) without a Tailscale address before the listener is torn down.
    nonisolated static let tailscaleGraceTicks = 3

    nonisolated enum ListenerAction: Equatable { case keep, waitForTailscale, start }

    /// 30 s after the first failed bind, doubling to at most 10 minutes.
    nonisolated static func retryDelay(failedBinds: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, failedBinds - 1))), 600)
    }

    /// What to do with a wanted listener this tick, by `host:port`. A listener on another
    /// address or port (Tailscale moved, the mirror port changed) rebinds at once; one that
    /// never bound, or failed, retries after `retryAfter`.
    nonisolated static func listenerAction(want: String?, bound: String?, pending: String?,
                                           secondsSinceAttempt: TimeInterval?, retryAfter: TimeInterval) -> ListenerAction {
        guard let want else { return .waitForTailscale }
        if bound == want || pending == want { return .keep }
        if bound != nil || pending != nil { return .start }
        if let since = secondsSinceAttempt, since < retryAfter { return .keep }
        return .start
    }

    func shutDown() {
        upgradeTimer?.invalidate()
        configTimer?.invalidate()
        usageTimer?.invalidate()
        reaper?.stop()
        // Asks for a clean close; the process may exit before the frame is flushed.
        rosterPublisher?.stop()
        // Shims first: a replacement daemon may take the socket the moment it is gone, and must
        // not resume a transcript whose old CLI is still alive.
        for session in store.openSessions { session.shim?.stop() }
        server?.stopTCP()
        server?.stopLocal()
    }
}
