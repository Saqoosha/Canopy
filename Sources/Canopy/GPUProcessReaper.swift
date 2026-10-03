import Darwin
import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "GPUReaper")

/// Kills WebKit GPU processes this app owns that WebKit has abandoned.
///
/// Measured 2026-10-03 on macOS 27.0.1: a GPU process that hangs at launch
/// (there, inside CoreAudio, waiting on a coreaudiod reply that never came)
/// is logged by WebKit as `became unresponsive, terminating it` and then NOT
/// terminated — it was still alive half an hour later. The page that had
/// connected to it stays connected: DOM, JS and clicks all work and nothing
/// is ever painted, so the pane is a white rectangle. SIGKILLing that process
/// recovers the page at once; WebKit launches a new GPU process and the page
/// reconnects to it. Reproduced by SIGSTOPping a Debug build's GPU process
/// during a launch restore.
///
/// A process pool has one GPU process, so any webview's
/// `_gpuProcessIdentifier` names the live one (0 when WebKit has none, which
/// is the state an abandoned process leaves behind). Every other GPU process
/// this app is responsible for is an orphan. Both lookups are SPI; when
/// either is missing, nothing is ever killed.
@MainActor
enum GPUProcessReaper {
    static let interval: TimeInterval = 5
    /// A GPU process younger than this may be one WebKit is still bringing
    /// up and has not reported yet. WebKit's own unresponsive check fires at 3 s.
    static let grace: TimeInterval = 10
    private static var timer: Timer?
    private static let gpuSelector = NSSelectorFromString("_gpuProcessIdentifier")

    static func start() {
        guard timer == nil else { return }
        guard responsibleFor != nil, WKWebView.instancesRespond(to: gpuSelector) else {
            logger.notice("[gpu-reaper] disabled: process SPI unavailable")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
    }

    private static func sweep() {
        guard let webView = SessionStore.shared?.openSessions.lazy.compactMap(\.webView).first else { return }
        let current = (webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        for pid in orphans(owned: ownedGPUProcesses(), current: current, now: Date(), grace: grace) {
            if kill(pid, SIGKILL) == 0 {
                logger.notice("[gpu-reaper] killed abandoned GPU process \(pid, privacy: .public) (WebKit's current: \(current, privacy: .public))")
            } else {
                let err = errno
                logger.error("[gpu-reaper] could not kill GPU process \(pid, privacy: .public): \(String(cString: strerror(err)), privacy: .public)")
            }
        }
    }

    nonisolated static func orphans(owned: [(pid: pid_t, startedAt: Date)], current: pid_t,
                                    now: Date, grace: TimeInterval) -> [pid_t] {
        owned.filter { $0.pid != current && now.timeIntervalSince($0.startedAt) >= grace }.map(\.pid)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    nonisolated private static let responsibleFor: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// `com.apple.WebKit.GPU` processes whose responsible process is this one.
    /// XPC services are reparented to launchd, so the parent pid says nothing.
    nonisolated static func ownedGPUProcesses() -> [(pid: pid_t, startedAt: Date)] {
        guard let responsibleFor else { return [] }
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var owned: [(pid: pid_t, startedAt: Date)] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                      .hasSuffix("/com.apple.WebKit.GPU"),
                  responsibleFor(pid) == me else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            owned.append((pid, Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))))
        }
        return owned
    }
}
