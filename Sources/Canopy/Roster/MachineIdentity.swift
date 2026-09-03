import Foundation
import IOKit
import Security
import os.log

/// Who this Mac is, to the roster.
///
/// Two fields, deliberately separate. The **id** keys the Durable Object and
/// every match; the **display name** is only ever rendered. Keeping them apart
/// is what makes renaming free — the id never moves, so a rename breaks no
/// pane and no pending notification.
enum MachineIdentity {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MachineIdentity")

    /// `IOPlatformUUID` — stable across renames, network changes and OS
    /// reinstalls. The hostname was rejected because it moves with the
    /// network, which is the one thing the id must not do.
    static func stableId() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            logger.error("IOPlatformExpertDevice not found; roster cannot identify this Mac")
            return nil
        }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// `scutil --get ComputerName`, which is what the user already sees in
    /// System Settings.
    static func defaultDisplayName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
    }

    /// Pure so the probe can pin the fallback. A blank setting must never
    /// publish an unnamed Mac — the roster's whole job is telling Macs apart.
    static func resolvedDisplayName(setting: String, fallback: String) -> String {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Write the relay secret to the Keychain. Deleting first is what makes
    /// this an upsert — `SecItemAdd` on an existing item fails with
    /// `errSecDuplicateItem` rather than replacing it.
    static func storeRelaySecret(_ secret: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
        ]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("could not store the relay secret: \(status, privacy: .public)")
        }
    }
}
