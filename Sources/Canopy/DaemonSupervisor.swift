import AppKit
import ServiceManagement
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "DaemonSupervisor")

/// Makes sure this build's daemon is serving its socket before a pane attaches.
/// Release relies on the LaunchAgent; a Debug build (not registered by default)
/// and a Release whose registration waits on approval start one directly.
enum DaemonSupervisor {
    enum Action: Equatable { case none, register, launch }

    static func action(socketLive: Bool, isDebugBuild: Bool, registration: SMAppService.Status) -> Action {
        if socketLive { return .none }
        if isDebugBuild { return .launch }
        return registration == .notRegistered || registration == .notFound ? .register : .launch
    }

    /// One start at a time: every restored pane asks at launch, and each launch would
    /// start another daemon racing for the same socket.
    @MainActor private static var inFlight: Task<Bool, Never>?

    /// True once the socket answers; gives up after 10 s.
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
        switch action(socketLive: DaemonPaths.socketIsLive(path: path), isDebugBuild: isDebug,
                      registration: DaemonRegistration.status()) {
        case .none:
            return true
        case .register:
            DaemonRegistration.ensureRegistered()
        case .launch:
            launch()
        }
        for _ in 0..<50 {
            if DaemonPaths.socketIsLive(path: path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        logger.error("daemon socket did not come up within 10 s")
        return false
    }

    /// A separate process, not a child: it must outlive this GUI.
    @MainActor
    private static func launch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = ["--daemon"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { logger.error("daemon launch failed: \(error.localizedDescription, privacy: .public)") }
        }
        logger.notice("launching a daemon for this build")
    }
}
