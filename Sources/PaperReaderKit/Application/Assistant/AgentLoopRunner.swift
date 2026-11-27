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
        var roundBudgetNotes: [Int: String] = [:]
        var finalReason: String?
        var callIDs = Set(prior.flatMap { $0 }.flatMap { $0.toolCalls ?? [] }.map(\.id))
        var repeatCounts: [String: Int] = [:]
        var roundSignatures: [String] = []
        var seenSearchResultIDs: Set<String> = []
        var consecutiveNoGainReadRounds = 0
        let searchReadTools: Set<String> = [
            "search_library", "search_reading_notes", "search_online", "recommend_related",
        ]

        toolLoop: while true {
            try await beforeRequest()
            let answerOnly = finalReason != nil || remainingRounds == 0 || remainingCalls == 0
            let budget =
                answerOnly
                ? "\(finalReason ?? "工具预算已用完。")工具已关闭。"
                : "当前剩余 \(remainingRounds) 轮工具、\(remainingCalls) 次调用（含本轮）。"
            let system = AgentMessage(role: "system", content: baseInstructions)
            let toolNames = await availableTools()
            var trailingBudget: AgentMessage?
            if let lastTool = current.lastIndex(where: { $0.role == "tool" }) {
                // Stamp each completed tool round at most once on its trailing `tool` payload so
                // assistant messages remain pure model output and earlier prefixes NEVER mutate
                // across rounds (preserving server-side KV Prompt Cache). When an answer-only
                // transition reuses an already-stamped round (e.g. overdraw or compaction), emit
                // the transition state in a trailing ephemeral user message instead.
                if roundBudgetNotes[lastTool] == nil {
                    roundBudgetNotes[lastTool] = budget
                } else if answerOnly {
                    trailingBudget = AgentMessage(role: "user", content: "（系统状态）" + budget)
                }
            } else if answerOnly, finalReason != nil {
                trailingBudget = AgentMessage(role: "user", content: "（系统状态）" + budget)
            }
            let budgetNoteBytes = roundBudgetNotes.values.reduce(0) { $0 + $1.utf8.count + 32 }
            let capabilities = ModelCapabilities.resolve(settings)
            let toolReserve =
                (answerOnly && !capabilities.keepsToolsWhenDisabled)
                ? 0 : AgentClient.toolPayloadBytes(for: toolNames)
            // Only the tool definitions actually advertised are sent, so reserve their real size.
            let fitted = try AgentContextCompactor.fit(
                system: system, prior: prior, current: current, maxContextBytes: limits.maxContextBytes,
                reservedBytes: toolReserve + budgetNoteBytes,
                personalContext: personalContext, trailing: trailingBudget)
            prior = fitted.prior
            current = fitted.current
            roundBudgetNotes = roundBudgetNotes.filter { $0.key < current.count }
            if let reason = fitted.finalReason {
                finalReason = reason
                continue toolLoop
            }
            var currentWithNotes =
                fitted.includedPersonalContext
                ? AgentContextCompactor.applyingPersonalContext(personalContext, to: current) : current
            for (index, note) in roundBudgetNotes where currentWithNotes.indices.contains(index) {
                currentWithNotes[index].content = Self.attachingBudgetNote(note, to: currentWithNotes[index].content)
            }
            var messages = [system] + prior.flatMap { $0 } + currentWithNotes
            if let trailingBudget { messages.append(trailingBudget) }
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
                // The completed turn keeps the exact request bytes (including personal context and
                // the budget stamps) so the next turn can reuse the full server-side prefix cache.
                try await onFinalAnswer(response, system, currentWithNotes, prior)
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
            let signatures = calls.map(Self.canonicalSignature)
            let roundSignature = signatures.joined(separator: ";;")
            let pingPongDetected =
                roundSignatures.count >= 3
                && roundSignature == roundSignatures[roundSignatures.count - 2]
                && roundSignatures[roundSignatures.count - 1] == roundSignatures[roundSignatures.count - 3]
                && roundSignature != roundSignatures[roundSignatures.count - 1]
            roundSignatures.append(roundSignature)
            let roundUnique = Set(signatures)
            var stuckIndices = Set<Int>()
            var warnIndices = Set<Int>()
            for (index, signature) in signatures.enumerated() {
                let priorCount = repeatCounts[signature, default: 0]
                if priorCount >= 2 {
                    stuckIndices.insert(index)
                } else if priorCount == 1 {
                    warnIndices.insert(index)
                }
            }
            for signature in roundUnique {
                repeatCounts[signature, default: 0] += 1
            }
            let outcome: BatchOutcome
            if pingPongDetected {
                let blocked = calls.map { call in
                    AgentMessage(
                        role: "tool",
                        content:
                            #"{"ok":false,"loop_detected":true,"message":"检测到交替重复的工具调用循环（A→B→A→B），已停止重复执行，请依据已有结果直接作答。"}"#,
                        toolCallID: call.id)
                }
                finalReason = "检测到交替重复的工具调用循环，已停止重复执行。"
                outcome = BatchOutcome(toolMessages: blocked)
            } else if stuckIndices.count == calls.count {
                let blocked = calls.map { call in
                    AgentMessage(
                        role: "tool",
                        content:
                            #"{"ok":false,"loop_detected":true,"message":"检测到连续三次相同的工具调用与参数，已中止重复执行，请依据已有结果直接作答或更换策略。"}"#,
                        toolCallID: call.id)
                }
                finalReason = "检测到连续重复工具调用，已停止重复执行。"
                outcome = BatchOutcome(toolMessages: blocked)
            } else if !stuckIndices.isEmpty {
                let runnable = calls.enumerated().compactMap { stuckIndices.contains($0.offset) ? nil : $0.element }
                let partial = try await executeBatch(runnable, current)
                var merged: [AgentMessage] = []
                var runnableCursor = 0
                for (index, call) in calls.enumerated() {
                    if stuckIndices.contains(index) {
                        merged.append(
                            AgentMessage(
                                role: "tool",
                                content:
                                    #"{"ok":false,"loop_detected":true,"message":"该调用已连续重复三次，本次未再执行，请更换参数或直接作答。"}"#,
                                toolCallID: call.id))
                    } else if runnableCursor < partial.toolMessages.count {
                        merged.append(partial.toolMessages[runnableCursor])
                        runnableCursor += 1
                    }
                }
                outcome = BatchOutcome(
                    toolMessages: merged, changedResearchOverview: partial.changedResearchOverview,
                    shouldStopEarly: partial.shouldStopEarly)
            } else {
                var executed = try await executeBatch(calls, current)
                if !warnIndices.isEmpty {
                    for index in warnIndices where executed.toolMessages.indices.contains(index) {
                        if let raw = executed.toolMessages[index].content,
                            let annotated = Self.annotatingLoopWarning(raw)
                        {
                            executed.toolMessages[index].content = annotated
                        }
                    }
                }
                outcome = executed
            }
            var finalOutcome = outcome
            let isSearchOnlyRound =
                !calls.isEmpty && calls.allSatisfy { searchReadTools.contains($0.function.name) }
            if isSearchOnlyRound, finalReason == nil, warnIndices.isEmpty, stuckIndices.isEmpty {
                let batchIDs = Self.extractResultIDs(from: finalOutcome.toolMessages)
                let newlyDiscovered = batchIDs.subtracting(seenSearchResultIDs)
                seenSearchResultIDs.formUnion(batchIDs)
                if newlyDiscovered.isEmpty {
                    consecutiveNoGainReadRounds += 1
                    if consecutiveNoGainReadRounds >= 3 {
                        finalReason = "连续三轮检索未获得新增有效资料，已停止继续检索，请直接依据已有证据作答。"
                    } else if consecutiveNoGainReadRounds == 2,
                        let lastIndex = finalOutcome.toolMessages.indices.last,
                        let raw = finalOutcome.toolMessages[lastIndex].content,
                        let annotated = Self.annotatingStallWarning(raw)
                    {
                        finalOutcome.toolMessages[lastIndex].content = annotated
                    }
                } else {
                    consecutiveNoGainReadRounds = 0
                }
            } else if !calls.isEmpty, !isSearchOnlyRound {
                consecutiveNoGainReadRounds = 0
            }
            // Do not mutate earlier `research_overview` payloads or wipe `prior` when the library
            // changes: the mutation tool's own receipt already carries `research_overview_changed`,
            // so keeping earlier messages untouched preserves the KV Prompt Cache prefix.
            current.append(contentsOf: finalOutcome.toolMessages)
            // Checkpoints contain only the real conversation. Per-round budget notes and the
            // personal context remain ephemeral request decorations.
            try await onCheckpoint(current, prior, system)
            if finalOutcome.shouldStopEarly { return }
        }
    }

    private static func canonicalSignature(_ call: AgentToolCall) -> String {
        let trimmed = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        {
            return call.function.name + "|" + String(decoding: canonical, as: UTF8.self)
        }
        return call.function.name + "|" + trimmed
    }

    private static func attachingBudgetNote(_ note: String, to raw: String?) -> String {
        let existing = raw ?? ""
        if let data = existing.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object["_system_budget"] = note
            if let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return existing + (existing.isEmpty ? "" : "\n") + "（系统状态）" + note
    }

    private static func annotatingLoopWarning(_ raw: String) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return nil
        }
        object["loop_warning"] = "此工具与参数已在前序轮次调用过，请勿重复相同查询；可直接作答或更换参数。"
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func annotatingStallWarning(_ raw: String) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return nil
        }
        object["stall_warning"] = "连续两轮检索未发现新的有效资料，请更换完全不同的检索策略或直接依据已有证据作答。"
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractResultIDs(from toolMessages: [AgentMessage]) -> Set<String> {
        var ids = Set<String>()
        for message in toolMessages {
            guard let raw = message.content,
                let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                let results = object["results"] as? [[String: Any]]
            else { continue }
            for row in results {
                for key in ["paper_id", "candidate_id", "reading_note_id", "memory_id", "block_id", "result_id"] {
                    if let value = row[key] as? String, !value.isEmpty {
                        ids.insert("\(key):\(value)")
                        break
                    }
                }
            }
        }
        return ids
    }
}
