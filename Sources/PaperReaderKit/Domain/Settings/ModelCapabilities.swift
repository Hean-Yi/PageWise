import Foundation

/// Provider quirks are configuration, not endpoint or model string checks scattered through the
/// request builders. Unknown OpenAI-compatible gateways inherit conservative defaults and can
/// still be recognised by their model family (for example `anthropic/claude-*` via OpenRouter).
public struct ModelCapabilities: Sendable, Equatable {
    public enum Family: String, Sendable {
        case openAI, anthropic, gemini, deepSeek, kimi, glm, qwen, other
    }

    public let family: Family
    public let fixedSampling: Bool
    public let usesCompletionTokenLimit: Bool
    public let rejectsJSONObjectResponseFormat: Bool
    public let supportsThinkingToggle: Bool
    public let disablesThinkingForStructuredOutput: Bool
    /// DeepSeek official keeps tool definitions when `tool_choice` is `none` so a completed tool
    /// round can be replayed for its reasoning. Other compatible endpoints omit them entirely.
    public let keepsToolsWhenDisabled: Bool

    public static func resolve(_ settings: ModelSettings) -> ModelCapabilities {
        let provider = ModelServicePreset.matching(settings)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endpoint = try? settings.endpointURL()
        let host = endpoint?.host?.lowercased() ?? ""
        let family = family(provider: provider, model: model, host: host)
        let officialDeepSeek = host == "api.deepseek.com" && endpoint?.port == nil
        let newerOpenAI =
            family == .openAI
            && (model.contains("gpt-5") || model.contains("gpt-6") || model.contains("o1")
                || model.contains("o3") || model.contains("o4"))
        let flash = family == .deepSeek || family == .glm ? model.hasSuffix("flash") : false
        return ModelCapabilities(
            family: family,
            fixedSampling: family == .anthropic || (family == .kimi && model.contains("kimi-k"))
                || newerOpenAI,
            usesCompletionTokenLimit: family == .openAI || family == .kimi,
            rejectsJSONObjectResponseFormat: family == .anthropic,
            supportsThinkingToggle: provider == .deepSeek || provider == .glm || officialDeepSeek,
            disablesThinkingForStructuredOutput: flash,
            keepsToolsWhenDisabled: officialDeepSeek)
    }

    private static func family(provider: ModelServicePreset, model: String, host: String) -> Family {
        switch provider {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .deepSeek: return .deepSeek
        case .kimi: return .kimi
        case .glm: return .glm
        case .qwen: return .qwen
        case .doubao, .grok, .mistral, .custom: break
        }
        // A custom gateway still names the upstream model. Match the family, not the host.
        if model.contains("claude") { return .anthropic }
        if model.contains("deepseek") { return .deepSeek }
        if model.contains("gemini") { return .gemini }
        if model.contains("kimi") || model.contains("moonshot") { return .kimi }
        if model.contains("glm") || model.contains("chatglm") { return .glm }
        if model.contains("qwen") || model.contains("qwq") { return .qwen }
        if model.contains("gpt-") || model.contains("o1") || model.contains("o3") || model.contains("o4") {
            return .openAI
        }
        return .other
    }
}
