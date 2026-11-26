import Foundation

public enum AgentToolConcurrency {
    public static let readOnlyTools: Set<String> = [
        "search_library", "search_reading_notes", "search_online", "recommend_related",
        "read_paper", "list_library", "research_overview",
    ]

    public static func canRunConcurrently(_ calls: [AgentToolCall]) -> Bool {
        calls.count > 1 && calls.allSatisfy { readOnlyTools.contains($0.function.name) }
    }
}

/// UI-agnostic bounded multi-round tool-calling loop with context compaction and budget tracking.
@MainActor
public enum AgentLoopRunner {
    public struct RequestContext: Sendable {
        public var system: AgentMessage
        public var prior: [[AgentMessage]]
        public var current: [AgentMessage]
        public var requestLimits: AgentLimits
        public var answerOnly: Bool
    }

    public struct BatchOutcome: Sendable {
        public var toolMessages: [AgentMessage]
        public var changedResearchOverview: Bool
        public var shouldStopEarly: Bool

        public init(
            toolMessages: [AgentMessage], changedResearchOverview: Bool = false, shouldStopEarly: Bool = false
        ) {
            self.toolMessages = toolMessages
            self.changedResearchOverview = changedResearchOverview
            self.shouldStopEarly = shouldStopEarly
        }
    }

    public static func run(
        client: any AgentCompleting,
        settings: ModelSettings,
        key: String,
        limits: AgentLimits,
        instructions: String,
        userQuestion: String,
        personalContext: String,
        priorHistory: [[AgentMessage]],
        availableTools: @MainActor @Sendable () async -> Set<String>,
        beforeRequest: @MainActor @Sendable () async throws -> Void,
        onPersonalContextIncluded: @MainActor @Sendable () async throws -> Void,
        onPartialText: @escaping @MainActor @Sendable (String) async throws -> Void,
        onPartialReasoning: (@MainActor @Sendable (String) async throws -> Void)?,
        onBudgetExceeded: @MainActor @Sendable () async -> Void = {},
        onAssistantResponse: @MainActor @Sendable (_ response: AgentMessage, _ isToolRound: Bool) async throws -> Void,
        executeBatch:
            @MainActor @Sendable (_ calls: [AgentToolCall], _ current: [AgentMessage]) async throws
            -> BatchOutcome,
        onCheckpoint:
            @MainActor @Sendable (
                _ current: [AgentMessage], _ prior: [[AgentMessage]],
                _ system: AgentMessage
            ) async throws -> Void,
        onFinalAnswer:
            @MainActor @Sendable (
                _ response: AgentMessage, _ finalSystem: AgentMessage,
                _ current: [AgentMessage], _ prior: [[AgentMessage]]
            ) async throws -> Void
    ) async throws {
        var remainingRounds = max(0, limits.maxRounds)
        var remainingCalls = max(0, limits.maxToolCalls)
        // Keep the system prompt and tool definitions byte-for-byte stable across tool rounds.
        // Only the most recent assistant tool-call carries the per-round remaining budget, so the
        // long cached prefix survives every request.
        let baseInstructions =
            instructions
            + "\n工具预算为 \(max(0, limits.maxRounds)) 轮、\(max(0, limits.maxToolCalls)) 次调用。同轮多项分别计数。按本轮目标规划，只合并确有需要的独立调用。为结果卡或写笔记留出一轮。剩余两轮或两次时优先交付；预算用尽后另有一次只作答的机会，依据已有证据说明已知及待核实之处。"
        var prior = Array(priorHistory.suffix(max(0, limits.maxHistoryTurns))).map { turn in
            turn.map { message in
                var clean = message
                // Reasoning belongs to the response that produced it. Replaying it in a later
                // reader turn wastes context and some gateways reject the non-standard field.
                clean.reasoningContent = nil
                return clean
            }
        }
        var current = [AgentMessage(role: "user", content: userQuestion)]
        var finalReason: String?
        var callIDs = Set(prior.flatMap { $0 }.flatMap { $0.toolCalls ?? [] }.map(\.id))

        toolLoop: while true {
            try await beforeRequest()
            let answerOnly = finalReason != nil || remainingRounds == 0 || remainingCalls == 0
            let budget =
                answerOnly
                ? "\(finalReason ?? "工具预算已用完。")工具已关闭。"
                : "当前剩余 \(remainingRounds) 轮工具、\(remainingCalls) 次调用（含本轮）。"
            let system = AgentMessage(role: "system", content: baseInstructions)
            let toolNames = await availableTools()
            // Only the tool definitions actually advertised are sent, so reserve their real size.
            // The tiny dynamic note rides on an existing assistant message; reserve a little extra.
            let fitted = try AgentContextCompactor.fit(
                system: system, prior: prior, current: current, maxContextBytes: limits.maxContextBytes,
                reservedBytes: AgentClient.toolPayloadBytes(for: toolNames) + budget.utf8.count + 64,
                personalContext: personalContext)
            prior = fitted.prior
            current = fitted.current
            if let reason = fitted.finalReason {
                finalReason = reason
                continue toolLoop
            }
            var messages =
                [system] + prior.flatMap { $0 }
                + (fitted.includedPersonalContext
                    ? AgentContextCompactor.applyingPersonalContext(personalContext, to: current) : current)
            if let index = messages.lastIndex(where: {
                $0.role == "assistant" && $0.toolCalls?.isEmpty == false
            }) {
                let existing = messages[index].content ?? ""
                messages[index].content = existing + (existing.isEmpty ? "" : "\n") + "（系统状态）" + budget
            }
            if fitted.includedPersonalContext, !personalContext.isEmpty {
                try await onPersonalContextIncluded()
            }
            var requestLimits = limits
            requestLimits.maxToolCalls = answerOnly ? 0 : remainingCalls
            requestLimits.availableToolNames = toolNames
            let response: AgentMessage
            do {
                response = try await client.respondStreaming(
                    settings: settings, key: key, messages: messages, limits: requestLimits,
                    onPartial: onPartialText, onReasoning: onPartialReasoning)
                if (response.toolCalls?.count ?? 0) > requestLimits.maxToolCalls {
                    throw AgentToolBudgetError.batchExceedsRemainingCalls
                }
            } catch AgentToolBudgetError.batchExceedsRemainingCalls {
                try await beforeRequest()
                await onBudgetExceeded()
                guard !answerOnly else {
                    throw ReaderError.message("工具已关闭，模型仍请求调用。已有结果可在工具记录中查看。")
                }
                finalReason = "上批调用超过剩余额度，整批未执行。"
                continue
            }
            guard response.role == "assistant",
                try JSONEncoder().encode(response).count <= limits.maxResponseBytes
            else {
                throw ReaderError.message("模型响应格式或长度无效。")
            }
            let calls = response.toolCalls ?? []
            if calls.isEmpty {
                try await onAssistantResponse(response, false)
                try await onFinalAnswer(response, system, current, prior)
                return
            }
            remainingRounds -= 1
            remainingCalls -= calls.count
            for call in calls {
                guard call.type == "function", !call.id.isEmpty, call.id.utf8.count <= 128,
                    callIDs.insert(call.id).inserted
                else {
                    throw ReaderError.message("工具调用标识重复或格式无效。")
                }
            }
            try await onAssistantResponse(response, true)
            current.append(response)
            let outcome = try await executeBatch(calls, current)
            if outcome.changedResearchOverview {
                prior.removeAll()
                let outdated = Set(
                    current.flatMap { $0.toolCalls ?? [] }.filter { $0.function.name == "research_overview" }
                        .map(\.id))
                for index in current.indices where current[index].toolCallID.map(outdated.contains) == true {
                    current[index].content = #"{"research_overview_changed":true}"#
                }
            }
            current.append(contentsOf: outcome.toolMessages)
            try await onCheckpoint(current, prior, system)
            if outcome.shouldStopEarly { return }
        }
    }
}
