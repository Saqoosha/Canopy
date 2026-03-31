import Foundation

/// Persists SSH host entries (e.g. "mbp", "user@server") in UserDefaults.
enum SSHHostStore {
    private static let key = "sshHosts"

    static func hosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ host: String) {
        var list = hosts().filter { $0 != host }
        list.insert(host, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ host: String) {
        let list = hosts().filter { $0 != host }
        UserDefaults.standard.set(list, forKey: key)
    }
}
