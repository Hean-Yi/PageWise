import Foundation

/// Builds the same provider-compatible request for testing, translation, chat and tool calls.
enum ChatCompletionRequest {
    static func make(
        settings: ModelSettings, key: String, messages: [AgentMessage], stream: Bool = false,
        maxOutputTokens: Int = 4_096, jsonOutput: Bool = false, reflow: Bool = false, tools: Bool = false
    ) throws -> URLRequest {
        let settings = try settings.normalized()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReaderError.message("请先在设置中保存 API Key。") }
        guard !key.contains(where: \.isWhitespace) else { throw ReaderError.message("API Key 中不能包含空格或换行。") }

        let provider = ModelServicePreset.matching(settings)
        let model = settings.model.lowercased()
        // Newer GPT and Claude families reject non-default sampling. Kimi's presets also fix sampling by model.
        let fixedSampling =
            provider == .anthropic || (provider == .kimi && model.hasPrefix("kimi-k"))
            || (provider == .openAI && (model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.first == "o"))
        let usesCompletionLimit = provider == .openAI || provider == .kimi
        let disableThinking =
            (reflow && provider == .glm && model == "glm-5.3-flash")
            || ((jsonOutput || reflow) && provider == .deepSeek && model == "deepseek-flash")
        let body = Body(
            model: settings.model, messages: messages, stream: stream,
            temperature: fixedSampling ? nil : settings.temperature,
            maxTokens: usesCompletionLimit ? nil : maxOutputTokens,
            maxCompletionTokens: usesCompletionLimit ? maxOutputTokens : nil,
            // Claude's compatibility API rejects json_object. The prompts and local schema checks still require JSON.
            responseFormat: jsonOutput && provider != .anthropic ? ["type": "json_object"] : nil,
            thinking: disableThinking ? ["type": "disabled"] : nil,
            tools: tools ? AgentClient.Tool.definitions : nil, toolChoice: tools ? "auto" : nil)
        var request = URLRequest(url: try settings.endpointURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private struct Body: Encodable {
        let model: String
        let messages: [AgentMessage]
        let stream: Bool
        let temperature: Double?
        let maxTokens: Int?
        let maxCompletionTokens: Int?
        let responseFormat: [String: String]?
        let thinking: [String: String]?
        let tools: [AgentClient.Tool]?
        let toolChoice: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature, thinking, tools
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
            case responseFormat = "response_format"
            case toolChoice = "tool_choice"
        }
    }
}
