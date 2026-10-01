import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonSupervisor")

/// Makes sure this build's daemon is serving its socket before a pane attaches.
/// A registered agent is started by launchd; the GUI starts one itself only when
/// nothing is registered (Debug), approval is pending, or launchd did not bring it up.
/// See docs/superpowers/specs/2026-10-01-headless-daemon-design.md.
enum DaemonSupervisor {
    enum Action: Equatable { case none, register, kickstart, launch }

    /// Registration decides, not build type: a Debug build registered with
    /// CANOPY_REGISTER_DAEMON=1 is launchd's too.
    static func action(socketLive: Bool, isDebugBuild: Bool, registration: SMAppService.Status) -> Action {
        if socketLive { return .none }
        switch registration {
        case .enabled: return .kickstart
        case .notRegistered, .notFound: return isDebugBuild ? .launch : .register
        default: return .launch
        }
    }

    /// One start at a time: every restored pane asks at launch.
    @MainActor private static var inFlight: Task<Bool, Never>?

    /// True once the socket answers.
    @MainActor
    static func ensureRunning() async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in await start() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    @MainActor
    private static func start() async -> Bool {
        let path = DaemonPaths.current
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let bundleId = Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"
        switch action(socketLive: DaemonPaths.socketIsLive(path: path), isDebugBuild: isDebug,
                      registration: DaemonRegistration.status()) {
        case .none:
            return true
        case .register:
            // RunAtLoad starts it, so give launchd the first try; launching here at once would
            // race launchd's for the socket. A direct launch is only the fallback.
            DaemonRegistration.ensureRegistered()
            if DaemonRegistration.status() == .enabled {
                if await waitForSocket(path, seconds: 15) { return true }
                logger.notice("launchd did not start the newly registered agent within 15 s; starting it directly")
            }
        case .kickstart:
            // A job that exited 0 (a quit, or losing the socket race) is not restarted by KeepAlive.
            kickstart(label: DaemonRegistration.label(bundleId: bundleId))
            if await waitForSocket(path, seconds: 15) { return true }
            logger.notice("launchd did not bring the daemon up within 15 s; starting it directly")
        case .launch:
            break
        }
        launch()
        if await waitForSocket(path, seconds: 10) { return true }
        logger.error("daemon socket did not come up within 10 s")
        return false
    }

    @MainActor
    private static func waitForSocket(_ path: String, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 5) {
            if DaemonPaths.socketIsLive(path: path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Without `-k`: a running job is left alone, a stopped one is started.
    private static func kickstart(label: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            logger.notice("asked launchd to start \(label, privacy: .public)")
        } catch {
            logger.error("launchctl kickstart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A plain child process, not `NSWorkspace.openApplication`: that registers the daemon with
    /// LaunchServices as a second instance of this app (issue #279). Not waited on; it outlives this GUI.
    private static func launch() {
        guard let executable = Bundle.main.executableURL else {
            logger.error("daemon launch failed: no executable URL")
            return
        }
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["--daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            logger.notice("launching a daemon for this build (pid \(proc.processIdentifier))")
        } catch {
            logger.error("daemon launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
