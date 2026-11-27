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
    private(set) var lastUsage: StreamUsage?
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
    private var fenceTickCount = 0
    private var inInlineCode = false
    private var sawInlineThinkOpen = false
    private var sawInlineThinkClose = false
    private var sawStructuredReasoning = false
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
                // Track Markdown code fences (``` or ````) and inline code spans (`) so literal `<think>`
                // examples inside paper discussions are never swallowed into reasoning. Reset inline code
                // across newlines so an unmatched backtick on one line never poisons subsequent lines.
                let inFencedCode = fenceTickCount > 0
                let nextSpecial = thinkCarry.firstIndex {
                    $0 == "`" || (inInlineCode && $0 == "\n") || (!inFencedCode && !inInlineCode && $0 == "<")
                }
                guard let special = nextSpecial else {
                    textDelta += thinkCarry
                    thinkCarry = ""
                    break
                }
                if special > thinkCarry.startIndex {
                    let prefix = String(thinkCarry[..<special])
                    if !(text.isEmpty && textDelta.isEmpty && thinkCarry[special] == "<"
                        && prefix.allSatisfy(\.isWhitespace))
                    {
                        textDelta += prefix
                    }
                    thinkCarry = String(thinkCarry[special...])
                }
                if thinkCarry.first == "\n" {
                    inInlineCode = false
                    textDelta.append(thinkCarry.removeFirst())
                    continue
                }
                if thinkCarry.first == "`" {
                    let tickEnd = thinkCarry.firstIndex { $0 != "`" } ?? thinkCarry.endIndex
                    let runLength = thinkCarry.distance(from: thinkCarry.startIndex, to: tickEnd)
                    // Hold back trailing backticks if they reach the end of the chunk and might form a fence.
                    if tickEnd == thinkCarry.endIndex && runLength < max(3, fenceTickCount) {
                        return (textDelta, reasoningDelta)
                    }
                    let ticks = String(thinkCarry[..<tickEnd])
                    if runLength >= 3 {
                        if fenceTickCount == 0 {
                            fenceTickCount = runLength
                            inInlineCode = false
                        } else if runLength >= fenceTickCount {
                            fenceTickCount = 0
                        }
                        textDelta += ticks
                        thinkCarry = String(thinkCarry[tickEnd...])
                        continue
                    }
                    if !inFencedCode {
                        inInlineCode.toggle()
                    }
                    textDelta += ticks
                    thinkCarry = String(thinkCarry[tickEnd...])
                    continue
                }
                let lower = thinkCarry.lowercased()
                if let tag = Self.inlineThinkTags.first(where: { lower.hasPrefix($0.open) }) {
                    thinkCarry = String(thinkCarry.dropFirst(tag.open.count))
                    inlineThinkState = .insideThink(closeTag: tag.close)
                    sawInlineThinkOpen = true
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
                    sawInlineThinkClose = true
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
        if !thinkCarry.isEmpty {
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
        // If a model opened an inline `<think>` block and hit `stop` without ever closing it,
        // promote the unclosed buffer back to visible text instead of discarding the entire reply.
        if finishReason == "stop", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            calls.isEmpty, sawInlineThinkOpen, !sawInlineThinkClose, !sawStructuredReasoning,
            case .insideThink = inlineThinkState, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            text = reasoning
            reasoning = ""
            inlineThinkState = .outsideThink
            try await onTextDelta?(text)
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
            try await consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) async throws {
        guard let string = String(data: line, encoding: .utf8) else {
            throw ReaderError.message("流式文本编码不完整，未保存当前段落。")
        }
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("data:") else { return }
        let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            try await flushThinkCarry()
            done = true
            return
        }
        guard !done, let json = payload.data(using: .utf8) else {
            throw ReaderError.message("流式响应格式不兼容，未保存当前段落。")
        }
        if let event = try? JSONDecoder().decode(Event.self, from: json) {
            if let usage = event.usage { lastUsage = usage }
            guard let choice = event.choices.first(where: { ($0.index ?? 0) == 0 }) else { return }
            if let value = choice.delta?.reasoningContent, !value.isEmpty {
                sawStructuredReasoning = true
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
            return
        }
        if let errorFrame = try? JSONDecoder().decode(ErrorEvent.self, from: json) {
            throw Self.mappedStreamError(errorFrame.error)
        }
        throw ReaderError.message("流式响应格式不兼容，未保存当前段落。")
    }

    private static func mappedStreamError(_ error: ErrorEvent.Detail) -> ReaderError {
        let signature = [error.type, error.code, error.message].compactMap { $0?.lowercased() }.joined(separator: " ")
        if signature.contains("rate_limit") || signature.contains("quota") || signature.contains("429") {
            return .message("模型服务限流或额度不足，请稍后重试。")
        }
        if signature.contains("context_length") || signature.contains("maximum context")
            || signature.contains("too long")
        {
            return .message("本次上下文超过模型服务限制，请缩小范围或新建对话。")
        }
        if signature.contains("auth") || signature.contains("api_key") || signature.contains("permission") {
            return .message("模型服务拒绝访问，请检查密钥、模型权限和 API 地址。")
        }
        return .message("模型服务在流式返回期间报告错误，未执行工具。")
    }

    private func flushTrailingLineIfNeeded() async throws {
        guard !pending.isEmpty else { return }
        let trailing = pending
        pending.removeAll()
        try await consumeLine(trailing)
    }

    func finish() async throws -> String {
        try await flushTrailingLineIfNeeded()
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard done, stopped, !result.isEmpty, pending.isEmpty else {
            throw ReaderError.message("翻译流中断，当前半段未保存；此前完成的段落仍保留。")
        }
        return result
    }

    func finishMessage() async throws -> (AgentMessage, String) {
        try await flushTrailingLineIfNeeded()
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

    struct StreamUsage: Decodable, Sendable, Equatable {
        struct PromptDetails: Decodable, Sendable, Equatable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }
        struct CompletionDetails: Decodable, Sendable, Equatable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptDetails?
        let completionTokensDetails: CompletionDetails?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
        }
    }

    private struct ErrorEvent: Decodable {
        struct Detail: Decodable {
            let type: String?
            let code: String?
            let message: String?
        }
        let error: Detail
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
        let usage: StreamUsage?
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
