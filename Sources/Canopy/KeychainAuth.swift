import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "KeychainAuth")

/// Reads CC OAuth tokens from macOS Keychain and builds an authStatus object.
/// CC CLI stores tokens under service "Claude Code-credentials", account = $USER.
enum KeychainAuth {
    /// Cached result to avoid spawning `security` on every message.
    /// Only accessed from main thread (WebViewContainer setup + ShimProcess message handling).
    private nonisolated(unsafe) static var cached: [String: Any]?

    /// Read authStatus as a dictionary (for injecting into extension messages).
    /// Results are cached after the first successful read.
    static func readAuthStatus() -> [String: Any]? {
        if let cached { return cached }
        guard let oauth = readOAuthFromKeychain() else { return nil }
        let scopes = oauth["scopes"] as? [String] ?? []
        let authMethod = scopes.contains("user:inference") ? "claudeai" : "console"
        let subscriptionType = oauth["subscriptionType"] as? String
        logger.info("Auth from Keychain: \(authMethod, privacy: .public)")
        let result: [String: Any] = [
            "authMethod": authMethod,
            "email": NSNull(), // Keychain has no email; webview expects the key
            "subscriptionType": subscriptionType ?? NSNull(),
        ]
        cached = result
        return result
    }

    /// Read authStatus as a JSON string (for HTML attribute injection).
    static func readAuthStatusJSON() -> String? {
        guard let dict = readAuthStatus() else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                logger.error("readAuthStatusJSON: UTF-8 encoding failed")
                return nil
            }
            return jsonStr
        } catch {
            logger.error("readAuthStatusJSON: serialization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func readOAuthFromKeychain() -> [String: Any]? {
        let username = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-a", username, "-w", "-s", "Claude Code-credentials"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            logger.error("Failed to run security command: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Read pipe before waitUntilExit to avoid deadlock if buffer fills
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            logger.warning("Keychain read failed: security exited with status \(proc.terminationStatus)")
            return nil
        }
        guard !output.isEmpty else {
            logger.warning("Keychain returned empty data")
            return nil
        }
        let keychainJSON: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                logger.warning("Keychain data is not a JSON dictionary")
                return nil
            }
            keychainJSON = parsed
        } catch {
            logger.error("Keychain JSON parse failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let oauth = keychainJSON["claudeAiOauth"] as? [String: Any] else {
            logger.warning("Keychain JSON missing 'claudeAiOauth' key")
            return nil
        }
        return oauth
    }
}
