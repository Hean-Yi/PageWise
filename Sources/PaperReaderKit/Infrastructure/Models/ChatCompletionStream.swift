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
    private var inlineThinkState: InlineThinkState = .outsideThink
    private var finishReason: String?
    private var lastEmittedTextBytes = 0
    private var lastEmittedReasoningBytes = 0
    private let emissionStride: Int
    private let maxToolCalls: Int?
    private let onPartial: @Sendable (String) async throws -> Void
    private let onReasoning: (@Sendable (String) async throws -> Void)?
    private let onTextDelta: (@Sendable (String) async throws -> Void)?
    private let onReasoningDelta: (@Sendable (String) async throws -> Void)?

    private enum InlineThinkState {
        case outsideThink
        case insideThink(closeTag: String)
    }

    init(
        maxToolCalls: Int? = nil, emissionStride: Int = 128,
        onPartial: @escaping @Sendable (String) async throws -> Void,
        onReasoning: (@Sendable (String) async throws -> Void)? = nil,
        onTextDelta: (@Sendable (String) async throws -> Void)? = nil,
        onReasoningDelta: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.maxToolCalls = maxToolCalls
        self.emissionStride = max(0, emissionStride)
        self.onPartial = onPartial
        self.onReasoning = onReasoning
        self.onTextDelta = onTextDelta
        self.onReasoningDelta = onReasoningDelta
    }

    /// Coalesce cumulative snapshots. Callers receive the same full-text contract, but SwiftUI
    /// is not asked to re-layout the entire answer for every SSE token.
    private func emitReasoning(force: Bool) async throws {
        guard let onReasoning else { return }
        let bytes = reasoning.utf8.count
        guard bytes > lastEmittedReasoningBytes,
            force || lastEmittedReasoningBytes == 0 || bytes - lastEmittedReasoningBytes >= emissionStride
        else { return }
        lastEmittedReasoningBytes = bytes
        try await onReasoning(reasoning)
    }

    private func emitText(force: Bool) async throws {
        let bytes = text.utf8.count
        guard bytes > lastEmittedTextBytes,
            force || lastEmittedTextBytes == 0 || bytes - lastEmittedTextBytes >= emissionStride
        else { return }
        lastEmittedTextBytes = bytes
        try await onPartial(text)
    }

    private func flush() async throws {
        try await emitReasoning(force: true)
        try await emitText(force: true)
    }

    private var thinkCarry = ""
    private static let inlineThinkTags: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thought>", "</thought>"),
        ("<thinking>", "</thinking>"),
    ]

    private func routeInlineContent(_ chunk: String) -> (textDelta: String, reasoningDelta: String) {
        thinkCarry += chunk
        var textDelta = ""
        var reasoningDelta = ""
        while !thinkCarry.isEmpty {
            switch inlineThinkState {
            case .outsideThink:
                guard let lt = thinkCarry.firstIndex(of: "<") else {
                    textDelta += thinkCarry
                    thinkCarry = ""
                    break
                }
                if lt > thinkCarry.startIndex {
                    let prefix = String(thinkCarry[..<lt])
                    // Ignore whitespace-only lead-in before an opening think tag at the start of a reply.
                    if !(text.isEmpty && textDelta.isEmpty && prefix.allSatisfy(\.isWhitespace)) {
                        textDelta += prefix
                    }
                    thinkCarry = String(thinkCarry[lt...])
                }
                let lower = thinkCarry.lowercased()
                if let tag = Self.inlineThinkTags.first(where: { lower.hasPrefix($0.open) }) {
                    thinkCarry = String(thinkCarry.dropFirst(tag.open.count))
                    inlineThinkState = .insideThink(closeTag: tag.close)
                    continue
                }
                if Self.inlineThinkTags.contains(where: { $0.open.hasPrefix(lower) && lower.count < $0.open.count }) {
                    return (textDelta, reasoningDelta)
                }
                textDelta.append(thinkCarry.removeFirst())
            case .insideThink(let closeTag):
                if let range = thinkCarry.range(of: closeTag, options: .caseInsensitive) {
                    reasoningDelta += thinkCarry[..<range.lowerBound]
                    var remainder = String(thinkCarry[range.upperBound...])
                    if text.isEmpty && textDelta.isEmpty {
                        remainder = remainder.replacingOccurrences(
                            of: #"^\s+"#, with: "", options: .regularExpression)
                    }
                    thinkCarry = remainder
                    inlineThinkState = .outsideThink
                    continue
                }
                // Hold back up to closeTag.count - 1 trailing chars in case the closing tag spans chunks.
                let keep = min(thinkCarry.count, closeTag.count - 1)
                let splitIndex = thinkCarry.index(thinkCarry.endIndex, offsetBy: -keep)
                if splitIndex > thinkCarry.startIndex {
                    reasoningDelta += thinkCarry[..<splitIndex]
                    thinkCarry = String(thinkCarry[splitIndex...])
                }
                return (textDelta, reasoningDelta)
            }
        }
        return (textDelta, reasoningDelta)
    }

    private func flushThinkCarry() async throws {
        guard !thinkCarry.isEmpty else { return }
        let trailing = thinkCarry
        thinkCarry = ""
        switch inlineThinkState {
        case .insideThink:
            reasoning += trailing
            try await onReasoningDelta?(trailing)
            try await emitReasoning(force: true)
        case .outsideThink:
            text += trailing
            try await onTextDelta?(trailing)
            try await emitText(force: true)
        }
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
                try await flushThinkCarry()
                done = true
                continue
            }
            guard !done, let json = payload.data(using: .utf8),
                let event = try? JSONDecoder().decode(Event.self, from: json)
            else { throw ReaderError.message("流式响应格式不兼容，未保存当前段落。") }
            guard let choice = event.choices.first(where: { ($0.index ?? 0) == 0 }) else { continue }
            if let value = choice.delta?.reasoningContent, !value.isEmpty {
                reasoning += value
                try await onReasoningDelta?(value)
                try await emitReasoning(force: false)
            }
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
                let routed = routeInlineContent(content)
                if !routed.reasoningDelta.isEmpty {
                    reasoning += routed.reasoningDelta
                    try await onReasoningDelta?(routed.reasoningDelta)
                    try await emitReasoning(force: false)
                }
                if !routed.textDelta.isEmpty {
                    text += routed.textDelta
                    try await onTextDelta?(routed.textDelta)
                    try await emitText(force: false)
                }
            }
            if let reason = choice.finishReason {
                guard reason == "stop" || (maxToolCalls != nil && reason == "tool_calls") else {
                    if reason == "length" { throw ModelStreamFailure.outputLimit }
                    if reason == "content_filter" { throw ModelStreamFailure.contentFilter }
                    throw ModelStreamFailure.unexpectedFinish
                }
                stopped = true
                finishReason = reason
                try await flushThinkCarry()
                try await flush()
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
