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
        let target = "gui/\(getuid())/\(DaemonRegistration.label(bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy"))"
        switch action(socketLive: DaemonPaths.socketIsLive(path: path), isDebugBuild: isDebug,
                      registration: DaemonRegistration.status()) {
        case .none:
            return true
        case .register:
            // RunAtLoad starts it, so give launchd the first try; launching here at once would
            // race launchd's for the socket. A direct launch is only the fallback.
            DaemonRegistration.ensureRegistered()
            if DaemonRegistration.status() == .enabled {
                guard let live = await waitForLaunchd(target: target, path: path) else { return false }
                if live { return true }
            }
        case .kickstart:
            // A job that exited 0 (a quit, or losing the socket race) is not restarted by KeepAlive.
            // Without `-k`: a running job is left alone, a stopped one is started.
            if let result = await launchctl(["kickstart", target]), result.status == 0 {
                logger.notice("asked launchd to start \(target, privacy: .public)")
                guard let live = await waitForLaunchd(target: target, path: path) else { return false }
                if live { return true }
            } else {
                logger.error("launchctl kickstart \(target, privacy: .public) failed; starting the daemon directly")
            }
        case .launch:
            break
        }
        launch()
        if await waitForSocket(path, seconds: 10) { return true }
        logger.error("daemon socket did not come up within 10 s")
        return false
    }

    enum AfterLaunchdTimeout: Equatable { case keepWaiting, launchDirectly }

    /// A daemon launchd is still running only binds late; starting a second one would race it for
    /// the socket, and the loser launchd's (exit 0) is never restarted.
    static func afterLaunchdTimeout(launchdPid: Int?) -> AfterLaunchdTimeout {
        launchdPid == nil ? .launchDirectly : .keepWaiting
    }

    /// The job's own `pid = N` line in `launchctl print`: one tab deep; nested blocks are deeper.
    static func launchdPid(fromPrint output: String) -> Int? {
        output.split(separator: "\n").lazy.compactMap { line in
            line.hasPrefix("\tpid = ") ? Int(line.dropFirst("\tpid = ".count)) : nil
        }.first
    }

    /// After launchd was asked to start the daemon: true once the socket answers, false when the
    /// caller should start one itself, nil when launchd holds a daemon that never answered.
    @MainActor
    private static func waitForLaunchd(target: String, path: String) async -> Bool? {
        if await waitForSocket(path, seconds: 15) { return true }
        let pid = await launchctl(["print", target]).flatMap { launchdPid(fromPrint: $0.output) }
        switch afterLaunchdTimeout(launchdPid: pid) {
        case .launchDirectly:
            logger.error("launchd is not running \(target, privacy: .public) after 15 s; starting the daemon directly")
            return false
        case .keepWaiting:
            if await waitForSocket(path, seconds: 15) { return true }
            logger.error("launchd's daemon (pid \(pid ?? -1)) has not opened its socket after 30 s; not starting a second one")
            return nil
        }
    }

    @MainActor
    private static func waitForSocket(_ path: String, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 5) {
            if DaemonPaths.socketIsLive(path: path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private struct LaunchctlResult { let status: Int32; let output: String }

    /// Runs `/bin/launchctl` off the main thread; a non-zero status logs launchctl's own stderr.
    private nonisolated static func launchctl(_ args: [String]) async -> LaunchctlResult? {
        await Task.detached {
            let proc = Process()
            let out = Pipe()
            let err = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = args
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
            } catch {
                logger.error("launchctl \(args.first ?? "", privacy: .public) could not run: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                logger.error("launchctl \(args.joined(separator: " "), privacy: .public) exited \(proc.terminationStatus): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
            }
            return LaunchctlResult(status: proc.terminationStatus, output: output)
        }.value
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
