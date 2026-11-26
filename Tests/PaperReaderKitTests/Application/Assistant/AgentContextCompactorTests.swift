import Foundation
import Testing

@testable import PaperReaderKit

private func compactableToolResult(rows: Int = 8) -> String {
    let results: [[String: Any]] = (0..<rows).map { index in
        [
            "result_id": "r\(index)",
            "title": "Result \(index)",
            "text": String(repeating: "registered evidence text ", count: 40),
        ]
    }
    return String(
        decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "results": results]), as: UTF8.self)
}

private func searchTurn(_ payload: String) -> [AgentMessage] {
    let call = AgentToolCall(id: "call_1", name: "search_library", arguments: #"{"query":"attention"}"#)
    return [
        .init(role: "user", content: "find"),
        .init(role: "assistant", toolCalls: [call]),
        .init(role: "tool", content: payload, toolCallID: call.id),
    ]
}

@Test func compactorSlimsOlderToolPayloadsWhileKeepingCallPairing() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let turn = searchTurn(compactableToolResult())
    let followup = [AgentMessage(role: "user", content: "continue")]
    let full = try JSONEncoder().encode([system] + turn + followup).count
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: [turn], current: followup, maxContextBytes: full - 500)
    #expect(fitted.compacted)
    #expect(fitted.finalReason == nil)
    #expect(fitted.prior.count == 1)
    let messages = try #require(fitted.prior.first)
    #expect(messages.count == 3)
    #expect(messages[1].toolCalls?.first?.id == "call_1")
    #expect(messages[2].toolCallID == "call_1")
    #expect(try #require(messages[2].content).utf8.count < compactableToolResult().utf8.count)
    #expect(try JSONEncoder().encode([system] + fitted.prior.flatMap { $0 } + fitted.current).count <= full - 500)
}

@Test func compactorAccountsForToolSchemaReserve() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let turn = searchTurn(compactableToolResult())
    let followup = [AgentMessage(role: "user", content: "next")]
    let full = try JSONEncoder().encode([system] + turn + followup).count
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: [turn], current: followup, maxContextBytes: full + 2_500, reservedBytes: 2_500)
    #expect(!fitted.compacted)
    #expect(fitted.prior.count == 1)
}

@Test func compactorDropsTheNewestToolGroupAndAsksForAnAnswerOnly() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let current = searchTurn(compactableToolResult())
    let userOnly = [AgentMessage(role: "user", content: "find")]
    let limit = try JSONEncoder().encode([system] + userOnly).count + 40
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: [], current: current, maxContextBytes: limit)
    #expect(fitted.finalReason?.contains("未纳入本次总结") == true)
    #expect(fitted.current == userOnly)
}

@Test func compactorReclaimsHistoryBeforeDroppingPersonalContext() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let prior = (0..<3).map { index in
        [
            AgentMessage(role: "user", content: "turn \(index)"),
            AgentMessage(role: "assistant", content: String(repeating: "history \(index) ", count: 80)),
        ]
    }
    var current = [AgentMessage(role: "user", content: "current question")]
    let personal = "读者偏好：先用结论，再给证据。"
    let trailing = AgentMessage(role: "user", content: "（系统状态）剩余 2 轮")
    func encoded(prior: [[AgentMessage]], includePersonal: Bool) throws -> Int {
        var messages = [system] + prior.flatMap { $0 }
        messages +=
            includePersonal
            ? AgentContextCompactor.applyingPersonalContext(personal, to: current) : current
        messages.append(trailing)
        return try JSONEncoder().encode(messages).count
    }
    let compactedSize = try encoded(prior: Array(prior.suffix(1)), includePersonal: true)
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: prior, current: current,
        maxContextBytes: compactedSize + 20, personalContext: personal, trailing: trailing)
    #expect(fitted.includedPersonalContext)
    #expect(fitted.prior.count < prior.count)
    #expect(fitted.current == current)
    #expect(!fitted.current.contains { $0.content?.contains("读者偏好") == true })
    var messages = [system] + fitted.prior.flatMap { $0 } + fitted.current
    messages = AgentContextCompactor.applyingPersonalContext(personal, to: messages)
    #expect(messages[messages.count - 1].content?.contains("读者偏好") == true)
}

@Test func compactorPreservesResearchOverviewAnchorsInsteadOfAnEmptyShell() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let topics = (0..<6).map { index in
        [
            "shelf": "Topic \(index)", "papers": index + 1, "papers_with_notes": index,
            "papers_with_discussions": 0, "papers_read": index,
            "sources": (0..<4).map {
                [
                    "paper_id": UUID().uuidString, "title": "Paper \($0)",
                    "excerpt": String(repeating: "excerpt", count: 20),
                ]
            },
        ] as [String: Any]
    }
    let memories = (0..<6).map { index in
        [
            "memory_id": UUID().uuidString, "status": "user_edited", "origin": "paper_reading",
            "text": String(repeating: "memory \(index) ", count: 20),
        ]
    }
    let overview: [String: Any] = [
        "paperCount": 12, "unfiledCount": 2, "shelfCount": 3,
        "topics": [["shelf": "Topic 1", "papers": 4]],
    ]
    let payload = String(
        decoding: try JSONSerialization.data(withJSONObject: [
            "ok": true, "overview": overview, "topics": topics, "memories": memories,
            "connections": [["kind": "related", "summary": "关联", "members": [UUID().uuidString]]],
            "sources": [["paper_id": UUID().uuidString, "title": "Paper", "excerpt": "evidence"]],
        ]), as: UTF8.self)
    let turn = [
        AgentMessage(role: "user", content: "overview"),
        AgentMessage(
            role: "assistant", toolCalls: [AgentToolCall(id: "c1", name: "research_overview", arguments: "{}")]),
        AgentMessage(role: "tool", content: payload, toolCallID: "c1"),
    ]
    let current = [AgentMessage(role: "user", content: "continue")]
    let full = try JSONEncoder().encode([system] + turn + current).count
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: [turn], current: current, maxContextBytes: full - 1_000)
    #expect(fitted.compacted)
    let slim = try #require(fitted.prior.first?.last?.content)
    #expect(slim.contains("total_topics"))
    #expect(slim.contains("total_memories"))
    #expect(slim.contains("Topic 0"))
    #expect(slim.utf8.count < payload.utf8.count)
}

@Test func compactorTrimsHistoricalReasoningWithoutBreakingToolPairing() throws {
    let system = AgentMessage(role: "system", content: "rules")
    let call = AgentToolCall(id: "call_r", name: "search_library", arguments: "{}")
    let reasoning = String(repeating: "推理过程 ", count: 300)
    let turn = [
        AgentMessage(role: "user", content: "find"),
        AgentMessage(role: "assistant", toolCalls: [call], reasoningContent: reasoning),
        AgentMessage(role: "tool", content: #"{"ok":true,"results":[]}"#, toolCallID: call.id),
    ]
    let followup = [AgentMessage(role: "user", content: "next")]
    let full = try JSONEncoder().encode([system] + turn + followup).count
    let fitted = try AgentContextCompactor.fit(
        system: system, prior: [turn], current: followup, maxContextBytes: full - 1_500)
    let assistant = try #require(fitted.prior.first?.dropFirst().first)
    #expect(assistant.toolCalls?.first?.id == "call_r")
    #expect(assistant.reasoningContent?.contains("已压缩") == true)
    #expect((assistant.reasoningContent?.count ?? .max) < reasoning.count)
}
