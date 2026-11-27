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
    /// Official endpoints that accept `tool_choice: "none"` alongside `tools` preserve KV Prompt
    /// Cache across the final answer-only turn. Other gateways omit `tools` when disabled.
    public let keepsToolsWhenDisabled: Bool
    /// Only providers whose tool-mode protocol expects or tolerates `reasoning_content` on
    /// assistant tool-call turns receive it back; strict OpenAI/Anthropic/Gemini gateways strip it.
    public let replaysReasoningInToolTurns: Bool
    public let isReasoningModel: Bool

    /// Reasoning models that cannot disable thinking during structured JSON generation need extra
    /// completion token headroom so `<think>` tokens do not truncate the JSON payload.
    public func structuredOutputTokenLimit(requested: Int) -> Int {
        let thinkingDisabled = disablesThinkingForStructuredOutput && supportsThinkingToggle
        guard isReasoningModel, !thinkingDisabled else { return requested }
        return max(requested, 4_096)
    }

    public static func resolve(_ settings: ModelSettings) -> ModelCapabilities {
        let provider = ModelServicePreset.matching(settings)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endpoint = try? settings.endpointURL()
        let host = endpoint?.host?.lowercased() ?? ""
        let family = family(provider: provider, model: model, host: host)
        let officialDeepSeek = host == "api.deepseek.com" && endpoint?.port == nil
        let newerOpenAI =
            family == .openAI
            && (hasModelToken(model, "gpt-5") || hasModelToken(model, "gpt-6")
                || hasModelToken(model, "o1") || hasModelToken(model, "o3") || hasModelToken(model, "o4"))
        let flash = family == .deepSeek || family == .glm ? model.hasSuffix("flash") : false
        let reasoningModel =
            newerOpenAI || model.contains("reasoner") || model.contains("thinking") || model.contains("qwq")
            || hasModelToken(model, "r1")
        return ModelCapabilities(
            family: family,
            fixedSampling: family == .anthropic || (family == .kimi && hasModelToken(model, "kimi-k"))
                || newerOpenAI,
            usesCompletionTokenLimit: family == .openAI || family == .kimi,
            rejectsJSONObjectResponseFormat: family == .anthropic,
            // Only official DeepSeek/GLM endpoints accept the non-standard `thinking` field;
            // unknown OpenAI-compatible gateways stay conservative so they do not reject the body.
            supportsThinkingToggle: provider == .deepSeek || provider == .glm || officialDeepSeek,
            disablesThinkingForStructuredOutput: flash,
            keepsToolsWhenDisabled: officialDeepSeek || provider == .openAI || provider == .anthropic,
            replaysReasoningInToolTurns: ![.openAI, .anthropic, .gemini].contains(family),
            isReasoningModel: reasoningModel)
    }

    private static func hasModelToken(_ model: String, _ token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return model.range(
            of: #"(?:^|[/:_.-])"# + escaped + #"(?:$|[/:_.-]|\d)"#, options: .regularExpression) != nil
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
        if model.contains("gpt-") || hasModelToken(model, "o1") || hasModelToken(model, "o3")
            || hasModelToken(model, "o4")
        {
            return .openAI
        }
        return .other
    }
}
