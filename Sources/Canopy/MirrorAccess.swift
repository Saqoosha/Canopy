import Darwin
import Foundation
import Security
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorAccess")

/// Who may attach to this Mac's sessions: the address the server binds and the password it checks.
enum MirrorAccess {
    static let urlScheme = "canopy-mirror"
    private static let keychainService = "sh.saqoo.Canopy.mirror"

    // MARK: Password

    /// The attach password, created on first use and kept in the Keychain, never in settings.json.
    static func token(createIfMissing: Bool) -> String? {
        if let stored = readToken() { return stored }
        guard createIfMissing else { return nil }
        return storeNewToken()
    }

    /// Replaces the password; nil means the old one is still in force.
    static func resetToken() -> String? {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("could not delete the mirror password (OSStatus \(status))")
            return nil
        }
        return storeNewToken()
    }

    /// Compares every byte whatever the input, so the time taken does not reveal a matching prefix.
    static func tokensMatch(_ provided: String, _ expected: String) -> Bool {
        let a = Array(provided.utf8), b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            difference |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return difference == 0 && !b.isEmpty
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: NSUserName(),
        ]
    }

    private static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("could not read the mirror password (OSStatus \(status))")
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    private static func storeNewToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            logger.error("could not generate a mirror password")
            return nil
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("could not store the mirror password (OSStatus \(status))")
            return nil
        }
        return token
    }

    // MARK: Address

    /// This Mac's Tailscale IPv4, the only address the server binds in normal use.
    static func tailscaleIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = ipv4
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buffer)
            if isTailscaleIPv4(text) { return text }
        }
        return nil
    }

    /// Tailscale hands out addresses from the CGNAT range 100.64.0.0/10.
    static func isTailscaleIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, text.split(separator: ".").count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    // MARK: Connection string

    /// What the phone pastes: `canopy-mirror://<host>:<port>?token=<password>`.
    static func connectionString(host: String, port: UInt16, token: String) -> String {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = host
        components.port = Int(port)
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.string ?? ""
    }
}
