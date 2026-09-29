import Foundation

/// Where the daemon's local socket lives. Keyed by bundle id because
/// `~/Library/Application Support/Canopy` is shared by Debug and Release,
/// so one path would let a Debug daemon take the Release app's socket.
enum DaemonPaths {
    /// `sun_path` is 104 bytes on Darwin, NUL included. Past it, `NWListener`
    /// still reports `.ready` but creates no socket file (measured), so the
    /// cap has to be enforced here rather than discovered at bind.
    static let maxSocketPathBytes = 103

    static func socketPath(bundleId: String, home: URL) -> String {
        let preferred = home
            .appendingPathComponent("Library/Application Support/Canopy", isDirectory: true)
            .appendingPathComponent("daemon-\(bundleId).sock").path
        if preferred.utf8.count <= maxSocketPathBytes { return preferred }
        // Per-user so two accounts on one Mac do not collide; the uid keeps it short.
        return "/tmp/canopy-\(getuid())-\(bundleId).sock"
    }

    /// The daemon's Tailscale port, or nil for no TCP listener. Off while
    /// Mirror is off: that toggle is the user's consent to a password-checked
    /// listener on Tailscale, and the daemon adds verbs to it rather than
    /// sidestepping it. A Debug build takes the next port, because
    /// settings.json is shared and both daemons bind the same address.
    static func tcpPort(mirrorEnabled: Bool, basePort: Int, bundleId: String) -> UInt16? {
        guard mirrorEnabled else { return nil }
        let port = bundleId.hasSuffix(".debug") ? basePort + 1 : basePort
        guard (1...65535).contains(port) else { return nil }
        return UInt16(port)
    }

    /// False only when `path` is provably stale (no file, or nobody accepting).
    /// Any other failure counts as live: unlinking a live socket would strand
    /// that daemon's sessions, and refusing to start is the recoverable mistake.
    static func socketIsLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxSocketPathBytes else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || (errno != ENOENT && errno != ECONNREFUSED)
    }

    static var current: String {
        socketPath(bundleId: Bundle.main.bundleIdentifier ?? "sh.saqoo.Canopy",
                   home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
