import Foundation

/// Initial values for a service. The saved endpoint and model remain independently editable.
public enum ModelServicePreset: String, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, deepSeek, qwen, kimi, glm, doubao, grok, mistral, custom

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .qwen: "阿里云百炼 · 千问"
        case .kimi: "月之暗面 · Kimi"
        case .glm: "智谱 GLM"
        case .doubao: "火山方舟 · 豆包"
        case .grok: "xAI Grok"
        case .mistral: "Mistral AI"
        case .custom: "自定义兼容接口"
        }
    }

    public var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: "https://api.moonshot.cn/v1"
        case .glm: ModelSettings.glmBaseURL
        case .doubao: "https://ark.cn-beijing.volces.com/api/v3"
        case .grok: "https://api.x.ai/v1"
        case .mistral: "https://api.mistral.ai/openai/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.4-mini"
        case .anthropic: "claude-haiku-4-5"
        case .gemini: "gemini-flash-latest"
        case .deepSeek: "deepseek-flash"
        case .qwen: "qwen-plus"
        case .kimi: "kimi-k3.1-pro"
        case .glm: "glm-5.3-flash"
        case .doubao: "doubao-seed-2-0-lite-260428"
        case .grok: "grok-4.3"
        case .mistral: "mistral-small-latest"
        case .custom: ""
        }
    }

    public static func matching(_ settings: ModelSettings) -> Self {
        guard let address = try? settings.endpointURL().absoluteString else { return .custom }
        return allCases.first { $0 != .custom && address == $0.baseURL + "/chat/completions" } ?? .custom
    }
}
