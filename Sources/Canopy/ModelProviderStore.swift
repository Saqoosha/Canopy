import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ModelProviderStore")

enum ModelProviderStore {
    private static let providersKey = "modelProviders"
    private static let selectedKey = "selectedProviderId"
    private static let migrationKey = "modelProviders.migrated"

    // MARK: - Persistence

    static func load() -> [ModelProvider] {
        guard let data = UserDefaults.standard.data(forKey: providersKey) else { return [] }
        do {
            return try JSONDecoder().decode([ModelProvider].self, from: data)
        } catch {
            logger.error("Failed to decode model providers: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func save(_ providers: [ModelProvider]) {
        guard let data = try? JSONEncoder().encode(providers) else {
            logger.error("Failed to encode model providers")
            return
        }
        UserDefaults.standard.set(data, forKey: providersKey)
    }

    // MARK: - Selection

    static func selectedId() -> String {
        UserDefaults.standard.string(forKey: selectedKey) ?? ""
    }

    static func select(_ id: String?) {
        UserDefaults.standard.set(id ?? "", forKey: selectedKey)
    }

    static func selectedProvider() -> ModelProvider? {
        let id = selectedId()
        guard !id.isEmpty else { return nil }
        return load().first { $0.id == id }
    }

    static func delete(_ id: String) {
        var providers = load()
        providers.removeAll { $0.id == id }
        save(providers)
        if selectedId() == id {
            select("")
        }
    }

    // MARK: - Migration

    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let baseURL = UserDefaults.standard.string(forKey: "launcher.customApiBaseURL") ?? ""
        guard !baseURL.isEmpty else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let authToken = UserDefaults.standard.string(forKey: "launcher.customApiAuthToken") ?? ""
        let opus = UserDefaults.standard.string(forKey: "launcher.customApiOpusModel") ?? ""
        let sonnet = UserDefaults.standard.string(forKey: "launcher.customApiSonnetModel") ?? ""
        let haiku = UserDefaults.standard.string(forKey: "launcher.customApiHaikuModel") ?? ""
        let subagent = UserDefaults.standard.string(forKey: "launcher.customApiSubagentModel") ?? ""

        var provider = ModelProvider()
        provider.id = UUID().uuidString
        provider.name = "Migrated Provider"
        provider.baseURL = baseURL
        provider.authToken = authToken
        provider.opusModel = opus
        provider.sonnetModel = sonnet
        provider.haikuModel = haiku
        provider.subagentModel = subagent

        var providers = load()
        providers.append(provider)
        save(providers)
        select(provider.id)

        // Clear legacy keys
        let legacyKeys = [
            "launcher.customApiEnabled", "launcher.customApiBaseURL",
            "launcher.customApiAuthToken", "launcher.customApiOpusModel",
            "launcher.customApiSonnetModel", "launcher.customApiHaikuModel",
            "launcher.customApiSubagentModel",
        ]
        for key in legacyKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        logger.info("Migrated legacy custom API config to ModelProvider id=\(provider.id, privacy: .public)")
    }
}
