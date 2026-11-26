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
