import Foundation

struct ModelProviderTemplate: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let opusModel: String
    let sonnetModel: String
    let haikuModel: String
    let subagentModel: String
}

struct ModelProvider: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var baseURL: String = ""
    var authToken: String = ""
    var opusModel: String = ""
    var sonnetModel: String = ""
    var haikuModel: String = ""
    var subagentModel: String = ""

    var isEnabled: Bool { !baseURL.isEmpty }

    static let templates: [ModelProviderTemplate] = [
        ModelProviderTemplate(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/anthropic",
            opusModel: "deepseek-v4-pro[1m]",
            sonnetModel: "deepseek-v4-pro[1m]",
            haikuModel: "deepseek-v4-flash",
            subagentModel: "deepseek-v4-flash"
        ),
        ModelProviderTemplate(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api",
            opusModel: "anthropic/claude-opus-4-7",
            sonnetModel: "anthropic/claude-sonnet-4-6",
            haikuModel: "anthropic/claude-haiku-4-5",
            subagentModel: "anthropic/claude-haiku-4-5"
        ),
        ModelProviderTemplate(
            id: "zhipu",
            name: "Zhipu GLM (z.ai)",
            baseURL: "https://api.z.ai/api/anthropic",
            opusModel: "GLM-4.6",
            sonnetModel: "GLM-4.6",
            haikuModel: "GLM-4.5-Air",
            subagentModel: "GLM-4.5-Air"
        ),
        ModelProviderTemplate(
            id: "qwen",
            name: "Alibaba Qwen (DashScope)",
            baseURL: "https://dashscope-intl.aliyuncs.com/apps/anthropic",
            opusModel: "qwen3-plus",
            sonnetModel: "qwen3-plus",
            haikuModel: "qwen3-flash",
            subagentModel: "qwen3-flash"
        ),
        ModelProviderTemplate(
            id: "kimi",
            name: "Kimi Moonshot",
            baseURL: "https://api.moonshot.ai/anthropic",
            opusModel: "kimi-k2.5",
            sonnetModel: "kimi-k2.5",
            haikuModel: "kimi-k2-flash",
            subagentModel: "kimi-k2-flash"
        ),
    ]

    init(id: String = UUID().uuidString, name: String = "", baseURL: String = "", authToken: String = "", opusModel: String = "", sonnetModel: String = "", haikuModel: String = "", subagentModel: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authToken = authToken
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.subagentModel = subagentModel
    }

    init(from template: ModelProviderTemplate) {
        self.id = UUID().uuidString
        self.name = template.name
        self.baseURL = template.baseURL
        self.opusModel = template.opusModel
        self.sonnetModel = template.sonnetModel
        self.haikuModel = template.haikuModel
        self.subagentModel = template.subagentModel
    }
}
