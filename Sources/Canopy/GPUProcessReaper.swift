import Darwin
import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "GPUReaper")

/// Kills WebKit GPU processes that WebKit once used and has since replaced.
///
/// WebKit bug 324797: WebKit logs `became unresponsive, terminating it` for a
/// hung GPU process, the kill fails, and a page still connected to it never
/// paints again (DOM, JS and clicks keep working). Seen here when the GPU
/// process hung at launch in CoreAudio. Killing that process lets WebKit
/// start a new one and the page paints at once; reproduced by SIGSTOPping a
/// Debug build's GPU process during a launch restore.
///
/// Only pids `_gpuProcessIdentifier` (SPI) has reported are ever killed, so a
/// misread SPI kills nothing and no other app's GPU process is touched.
@MainActor
enum GPUProcessReaper {
    static let interval: TimeInterval = 1
    /// Spares a GPU process WebKit may still be switching to.
    static let grace: TimeInterval = 10
    private static var timer: Timer?
    private static var seen: Set<pid_t> = []
    private static let gpuSelector = NSSelectorFromString("_gpuProcessIdentifier")

    static func start() {
        guard timer == nil else { return }
        guard WKWebView.instancesRespond(to: gpuSelector) else {
            logger.notice("[gpu-reaper] disabled: _gpuProcessIdentifier unavailable")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
    }

    private static func sweep() {
        guard let webView = SessionStore.shared?.openSessions.lazy.compactMap(\.webView).first,
              let current = (webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value
        else { return }
        if current > 0 { seen.insert(current) }
        var alive: [(pid: pid_t, startedAt: Date)] = []
        for pid in seen {
            if let started = gpuProcessStart(pid) { alive.append((pid, started)) } else { seen.remove(pid) }
        }
        for pid in orphans(owned: alive, current: current, now: Date(), grace: grace) {
            seen.remove(pid)
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

    /// Start time of `pid` if it is still a WebKit GPU process; nil once it
    /// has exited or the pid now belongs to something else.
    private static func gpuProcessStart(_ pid: pid_t) -> Date? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                  .hasSuffix("/com.apple.WebKit.GPU") else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
