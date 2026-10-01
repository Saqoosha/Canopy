import Network

/// Where a `RemoteMirrorBridge` connects: another Mac's server over Tailscale,
/// or this Mac's daemon over its Unix socket.
enum MirrorEndpoint: Equatable {
    case tcp(host: String, port: UInt16)
    case unix(path: String)

    /// The local socket is trusted by file permission (see `MirrorServer.startLocal`).
    var needsToken: Bool {
        if case .tcp = self { return true }
        return false
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .tcp(let host, let port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        case .unix(let path): .unix(path: path)
        }
    }

    /// TCP keeps a keepalive because a server that dies without its FIN reaching
    /// us leaves the socket ESTABLISHED forever (measured: studio's server
    /// SIGKILLed over Tailscale). 15 s idle, 15 s between probes, 3 probes: ~45 s,
    /// the budget MacroPad's remote transport and SSH remote use. A Unix socket's
    /// peer dying closes it, so it needs none.
    var parameters: NWParameters {
        switch self {
        case .tcp:
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 3
            return NWParameters(tls: nil, tcp: tcp)
        case .unix:
            return .tcp
        }
    }
}
