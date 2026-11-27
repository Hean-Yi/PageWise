import Foundation

/// Builds the same provider-compatible request for testing, translation, chat and tool calls.
enum ChatCompletionRequest {
    enum ToolChoice: String {
        case auto
        case disabled = "none"
    }

    static func make(
        settings: ModelSettings, key: String, messages: [AgentMessage], stream: Bool = false,
        maxOutputTokens: Int = 4_096, jsonOutput: Bool = false, reflow: Bool = false, toolChoice: ToolChoice? = nil,
        availableToolNames: Set<String>? = nil
    ) throws -> URLRequest {
        let settings = try settings.normalized()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReaderError.message("请先在设置中保存 API Key。") }
        guard !key.contains(where: \.isWhitespace) else { throw ReaderError.message("API Key 中不能包含空格或换行。") }

        let capabilities = ModelCapabilities.resolve(settings)
        let fixedSampling = capabilities.fixedSampling
        let usesCompletionLimit = capabilities.usesCompletionTokenLimit
        let disableThinking =
            (jsonOutput || reflow) && capabilities.disablesThinkingForStructuredOutput
            && capabilities.supportsThinkingToggle
        let tools =
            toolChoice == nil
            ? []
            : AgentClient.Tool.definitions.filter { tool in
                availableToolNames?.contains(tool.function.name) ?? true
            }
        // A completed assistant answer has no tool round to continue. For tool-call turns, only
        // replay `reasoning_content` to providers whose wire schema accepts it.
        let requestMessages = messages.map { message -> AgentMessage in
            guard message.role == "assistant" else { return message }
            let keepReasoning =
                capabilities.replaysReasoningInToolTurns && message.toolCalls?.isEmpty == false
            guard !keepReasoning, message.reasoningContent != nil else { return message }
            var clean = message
            clean.reasoningContent = nil
            return clean
        }
        let body = Body(
            model: settings.model, messages: requestMessages, stream: stream,
            temperature: fixedSampling ? nil : settings.temperature,
            maxTokens: usesCompletionLimit ? nil : maxOutputTokens,
            maxCompletionTokens: usesCompletionLimit ? maxOutputTokens : nil,
            // Claude's compatibility API rejects json_object. The prompts and local schema checks still require JSON.
            responseFormat: jsonOutput && !capabilities.rejectsJSONObjectResponseFormat ? ["type": "json_object"] : nil,
            thinking: disableThinking ? ["type": "disabled"] : nil,
            tools: tools.isEmpty ? nil : tools, toolChoice: tools.isEmpty ? nil : toolChoice?.rawValue)
        var request = URLRequest(url: try settings.endpointURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
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
