import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "JSStringLiteral")

/// Escape a Swift string into a JS string literal for `evaluateJavaScript`.
/// `JSONSerialization` rather than hand-rolled escaping, so quotes, backslashes
/// and newlines cannot break out of the literal.
enum JSStringLiteral {
    static func make(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8)
        else {
            logger.error("failed to encode a string as a JS literal")
            return "\"\""
        }
        return literal
    }
}
