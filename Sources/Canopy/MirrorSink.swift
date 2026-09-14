import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorSink")

/// One client of a session's `ShimProcess` besides its primary webview.
@MainActor
protocol MirrorSink: AnyObject {
    /// One host→webview payload, already in the `from-extension` envelope.
    func deliver(_ payload: [String: Any])
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
