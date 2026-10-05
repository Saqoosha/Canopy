import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorSink")

/// One client of a session's `ShimProcess` besides its primary webview.
@MainActor
protocol MirrorSink: AnyObject {
    /// One host→webview payload, already in the `from-extension` envelope.
    func deliver(_ payload: [String: Any])

    /// Where this client is watching from, for `canopy-remote-open.sh` to open
    /// files on. Nil unless the client is another Mac reachable by ssh - the
    /// phone cannot run `open`, and the session's own webview is already here.
    var openRedirectHost: String? { get }

    /// Whether this client takes the session's `open` redirect as
    /// `MirrorFileWire` frames. Only a Mac: the phone has no `open` to stand in for.
    var acceptsFileTransfers: Bool { get }

    /// Whether a file this client itself clicked may come back to it as
    /// `MirrorFileWire` frames: any client that asked (`"files": true`), the
    /// phone included. Narrower than `acceptsFileTransfers`, which also takes
    /// the session's `open` redirect.
    var acceptsClickedFiles: Bool { get }

    /// A Mac's Canopy that asked for UI frames at attach (`"ui": true`).
    var acceptsUI: Bool { get }

    /// On this Mac, over the daemon's local socket.
    var isLocalClient: Bool { get }

    /// Whether this client said at attach (`"restart": true`) that it re-attaches by
    /// itself after a `daemon_restarting` notice, so a daemon upgrade need not wait for it.
    var reattachesAfterRestart: Bool { get }

    /// UI the daemon cannot show itself (`MirrorUIFrame`).
    func deliverUI(_ frame: MirrorUIFrame)
}

extension MirrorSink {
    var openRedirectHost: String? { nil }
    var acceptsFileTransfers: Bool { false }
    var acceptsClickedFiles: Bool { false }
    var acceptsUI: Bool { false }
    var isLocalClient: Bool { false }
    var reattachesAfterRestart: Bool { false }
    func deliverUI(_ frame: MirrorUIFrame) {}
}

extension WKWebView: MirrorSink {
    func deliver(_ payload: [String: Any]) {
        let jsPayload: String
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                logger.error("deliver: UTF-8 encode failed")
                return
            }
            jsPayload = jsonStr
        } catch {
            logger.error("deliver: JSON serialization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        evaluateJavaScript("window.postMessage(\(jsPayload),'*')") { _, error in
            if let error {
                logger.error("deliver JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
