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
    ///
    /// The empty-secret guard runs BEFORE the delete, deliberately: an empty
    /// submit is the natural result of tabbing through the Settings form and
    /// pressing Return with the (never-seeded, so always blank-looking)
    /// SecureField untouched. That must be a no-op, not a silent delete of a
    /// working secret — see the Settings field's stored-secret indicator,
    /// which is the other half of this fix.
    static func storeRelaySecret(_ secret: String) {
        guard !secret.isEmpty else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
        ]
        // Update in place, and add ONLY when there is nothing to update.
        // The previous shape was delete-then-add, which loses the stored
        // secret outright whenever the add fails — it logged and moved on,
        // leaving the user with no secret and a Settings field that still
        // said one was stored. Found by review on PR #177; the phone app had
        // the same shape in its own Settings and was fixed the same day.
        let data = Data(secret.utf8)
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("could not store the relay secret: \(addStatus, privacy: .public)")
            }
        } else if status != errSecSuccess {
            // Anything else is a real failure and must NOT be followed by an
            // add: the existing item is still there and still correct.
            logger.error("could not update the relay secret: \(status, privacy: .public)")
        }
    }

    /// Whether a relay secret is currently stored — never returns the value
    /// itself (`kSecReturnData: false`), so the Settings field can say
    /// "A secret is stored" without ever reading it back.
    static func hasRelaySecret() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
