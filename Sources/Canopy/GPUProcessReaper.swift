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
    /// How long a pid must go unreported before it counts as abandoned, so a
    /// moment where every webview reads 0 does not cost the live process.
    static let grace: TimeInterval = 10
    private static var timer: Timer?
    /// Start time pins the pid against reuse; `lastInUse` is the last sweep
    /// that saw a webview report it.
    private static var seen: [pid_t: (startedAt: Date, lastInUse: Date)] = [:]
    private static let gpuSelector = NSSelectorFromString("_gpuProcessIdentifier")

    static func start() {
        guard timer == nil else { return }
        guard WKWebView.instancesRespond(to: gpuSelector) else {
            logger.notice("[gpu-reaper] disabled: _gpuProcessIdentifier unavailable")
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func sweep() {
        // A webview whose WebContent process died reports 0, so ask them all.
        let webViews = SessionStore.shared?.openSessions.compactMap(\.webView) ?? []
        let reported = webViews.map { ($0.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value }
        guard !reported.isEmpty, !reported.contains(nil) else { return }
        let current = Set(reported.compactMap { $0 }.filter { $0 > 0 })
        let now = Date()
        for pid in current {
            if seen[pid] != nil {
                seen[pid]?.lastInUse = now
            } else if let started = gpuProcessStart(pid) {
                seen[pid] = (started, now)
            }
        }
        var tracked: [(pid: pid_t, lastInUse: Date)] = []
        for (pid, entry) in seen where !current.contains(pid) {
            // Exited, or the pid now names a different process.
            guard gpuProcessStart(pid) == entry.startedAt else { seen[pid] = nil; continue }
            tracked.append((pid, entry.lastInUse))
        }
        for pid in orphans(tracked: tracked, current: current, now: now, grace: grace) {
            seen[pid] = nil
            if kill(pid, SIGKILL) == 0 {
                logger.notice("[gpu-reaper] killed abandoned GPU process \(pid, privacy: .public) (in use: \(current.sorted(), privacy: .public))")
            } else {
                let err = errno
                logger.error("[gpu-reaper] could not kill GPU process \(pid, privacy: .public): \(String(cString: strerror(err)), privacy: .public)")
            }
        }
    }

    nonisolated static func orphans(tracked: [(pid: pid_t, lastInUse: Date)], current: Set<pid_t>,
                                    now: Date, grace: TimeInterval) -> [pid_t] {
        tracked.filter { !current.contains($0.pid) && now.timeIntervalSince($0.lastInUse) >= grace }.map(\.pid)
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
