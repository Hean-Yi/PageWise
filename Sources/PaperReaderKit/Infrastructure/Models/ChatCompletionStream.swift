import Foundation

extension ModelClient {
    public func completeStream(
        settings: ModelSettings, key: String, maxOutputTokens: Int = 4096, system: String, user: String,
        onPartial: @escaping @Sendable (String) async throws -> Void
    ) async throws -> String {
        try await completeStream(
            settings: settings, key: key, maxOutputTokens: maxOutputTokens, system: system, user: user,
            reflow: false, onPartial: onPartial)
    }

    /// The flag distinguishes the verified reflow policy from generic chat requests.
    func completeStream(
        settings: ModelSettings, key: String, maxOutputTokens: Int, system: String, user: String,
        reflow: Bool, reflowPlainText: Bool = false,
        onPartial: @escaping @Sendable (String) async throws -> Void
    ) async throws -> String {
        let request = try ChatCompletionRequest.make(
            settings: settings, key: key,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)], stream: true,
            maxOutputTokens: maxOutputTokens, jsonOutput: reflow && !reflowPlainText, reflow: reflow)
        let decoder = ChatCompletionStreamDecoder(onPartial: onPartial)
        let response = try await transport.stream(for: request) { data in try await decoder.consume(data) }
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw ReaderError.message("模型服务拒绝访问，请检查密钥、模型权限和 API 地址。")
        case 429: throw ReaderError.message("模型服务限流或额度不足，请稍后重试。已完成段落已保留。")
        default: throw ReaderError.message("模型请求失败（HTTP \(response.statusCode)），未自动重试。")
        }
        try Task.checkCancellation()
        return try await decoder.finish()
    }
}

/// Consumes newline-delimited SSE data, including arbitrary UTF-8/network splits.
actor ChatCompletionStreamDecoder {
    private var pending = Data()
    private var text = ""
    private var stopped = false
    private var done = false
    private var received = 0
    private var calls: [Int: AgentToolCall] = [:]
    private var reasoning = ""
    private var finishReason: String?
    private let maxToolCalls: Int?
    private let onPartial: @Sendable (String) async throws -> Void
    init(maxToolCalls: Int? = nil, onPartial: @escaping @Sendable (String) async throws -> Void) {
        self.maxToolCalls = maxToolCalls
        self.onPartial = onPartial
    }

    func consume(_ data: Data) async throws {
        received += data.count
        guard received <= 2_000_000 else { throw ReaderError.message("流式响应过大，未保存当前段落。") }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let string = String(data: line, encoding: .utf8) else {
                throw ReaderError.message("流式文本编码不完整，未保存当前段落。")
            }
            let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("data:") else { continue }
            let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                done = true
                continue
            }
            guard !done, let json = payload.data(using: .utf8),
                let event = try? JSONDecoder().decode(Event.self, from: json)
            else { throw ReaderError.message("流式响应格式不兼容，未保存当前段落。") }
            guard let choice = event.choices.first(where: { ($0.index ?? 0) == 0 }) else { continue }
            if let value = choice.delta?.reasoningContent { reasoning += value }
            for part in choice.delta?.toolCalls ?? [] {
                guard let maxToolCalls, !stopped, part.index >= 0 else {
                    throw ReaderError.message("流式工具调用无效，未执行。")
                }
                guard part.index < maxToolCalls else { throw AgentToolBudgetError.batchExceedsRemainingCalls }
                var call = calls[part.index] ?? AgentToolCall(id: "", name: "", arguments: "")
                if let id = part.id { call.id += id }
                if let type = part.type { call.type = type }
                if let extra = part.extraContent { call.extraContent = extra }
                call.function.name += part.function?.name ?? ""
                call.function.arguments += part.function?.arguments ?? ""
                calls[part.index] = call
            }
            if let content = choice.delta?.content, !content.isEmpty {
                guard !stopped, text.utf8.count + content.utf8.count <= 200_000 else {
                    throw ReaderError.message("流式段落状态无效，未保存当前段落。")
                }
                text += content
                try await onPartial(text)
            }
            if let reason = choice.finishReason {
                guard reason == "stop" || (maxToolCalls != nil && reason == "tool_calls") else {
                    if reason == "length" { throw ModelStreamFailure.outputLimit }
                    if reason == "content_filter" { throw ModelStreamFailure.contentFilter }
                    throw ModelStreamFailure.unexpectedFinish
                }
                stopped = true
                finishReason = reason
            }
        }
    }

    func finish() throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard done, stopped, !result.isEmpty, pending.isEmpty else {
            throw ReaderError.message("翻译流中断，当前半段未保存；此前完成的段落仍保留。")
        }
        return result
    }

    func finishMessage() throws -> (AgentMessage, String) {
        guard done, stopped, pending.isEmpty, let finishReason else {
            throw ReaderError.message("模型流式响应中断，未执行工具。")
        }
        return (
            AgentMessage(
                role: "assistant", content: text.isEmpty ? nil : text,
                toolCalls: calls.isEmpty ? nil : calls.keys.sorted().compactMap { calls[$0] },
                reasoningContent: reasoning.isEmpty ? nil : reasoning), finishReason
        )
    }

    private struct Event: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Tool: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let id: String?
                    let type: String?
                    let function: Function?
                    let extraContent: AgentToolCall.ExtraContent?
                    enum CodingKeys: String, CodingKey {
                        case index, id, type, function
                        case extraContent = "extra_content"
                    }
                }
                let content: String?
                let reasoningContent: String?
                let toolCalls: [Tool]?
                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }
            let index: Int?
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case index, delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }
}

public enum ModelStreamFailure: Error, LocalizedError, Sendable {
    case outputLimit, contentFilter, unexpectedFinish
    public var errorDescription: String? {
        switch self {
        case .outputLimit: "模型返回 length：本次输出额度耗尽（可能包含推理消耗），已完成段落已保存，可继续。"
        case .contentFilter: "模型服务返回 content_filter，当前内容未完成；已完成段落已保存。"
        case .unexpectedFinish: "模型返回非正常结束状态，当前内容未完成；已完成段落已保存。"
        }
    }
}
