import Foundation
import Testing

@testable import PaperReaderKit

private actor RecoveryTransport: HTTPTransport {
    var calls = 0
    var translations = 0
    let duplicatePlan: Bool
    let interruptSecond: Bool
    init(duplicatePlan: Bool = false, interruptSecond: Bool = false) {
        self.duplicatePlan = duplicatePlan
        self.interruptSecond = interruptSecond
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        calls += 1
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let input = try #require(messages.last?["content"])
        let output: String
        if body["response_format"] != nil {
            let value = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let sources = try #require(value["sources"] as? [[String: Any]])
            let blocks = sources.enumerated().map { index, source in
                [
                    "kind": index == 0 ? "front_matter" : "paragraph",
                    "source_ids": [duplicatePlan ? "s0" : source["source_id"] as! String],
                ] as [String: Any]
            }
            output = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]), as: UTF8.self)
        } else {
            translations += 1
            #expect(!input.hasPrefix("{"))
            output = "这是一个完整自然段的译文，保留引用和完整句子。"
        }
        let packet = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": output]]]])
        try await onData(Data("data: ".utf8) + packet + Data("\n\n".utf8))
        let reason = interruptSecond && translations == 2 ? "length" : "stop"
        try await onData(
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private actor RecoveryResult {
    var plan: AIReflowPlan?
    var blocks: [BilingualBlock] = []
    func accept(_ value: AIReflowPlan) { plan = value }
    func publish(_ value: BilingualBlock) {
        #expect(plan != nil)
        blocks.append(value)
    }
}

@Test(arguments: [false, true]) func recoveryUsesWholeParagraphsAndNeverPublishesTruncatedTranslation(interrupt: Bool)
    async throws
{
    let transport = RecoveryTransport(interruptSecond: interrupt)
    let capture = RecoveryResult()
    let group = UUID()
    let sources = ["Correspondence: person@example.invalid", "First whole paragraph.", "Second whole paragraph."].map {
        text in
        var block = TextBlock(sourcePage: 0, text: text)
        block.reflowOrderGroup = group
        return block
    }
    let client = ModelClient(transport: transport)
    do {
        try await client.recoverReflowAndTranslate(
            sources: sources, title: "Fixture", settings: recoverySettings(), key: "fixture-only",
            acceptedPlan: nil, committedPlanBlockIDs: [],
            onPlan: { await capture.accept($0) }, onDraft: { _, _ in },
            onBlock: { block, _ in await capture.publish(block) })
        #expect(!interrupt)
    } catch ModelStreamFailure.outputLimit { #expect(interrupt) }
    let blocks = await capture.blocks
    #expect(blocks.count == (interrupt ? 2 : 3))
    #expect(blocks.first?.block.excludedFromReading == true)
    #expect(blocks.first?.translation == nil)
    #expect(blocks[1].block.text == sources[1].text)
    #expect(blocks[1].block.reflowProvenance?.first?.sourceID == sources[1].id)
    #expect(await transport.calls == 3)
    if interrupt {
        let plan = try #require(await capture.plan)
        let resumed = RecoveryTransport()
        try await ModelClient(transport: resumed).recoverReflowAndTranslate(
            sources: sources, title: "Fixture", settings: recoverySettings(), key: "fixture-only",
            acceptedPlan: plan, committedPlanBlockIDs: Set(blocks.map { $0.block.id }),
            onPlan: { _ in Issue.record("A saved plan must not be rewritten") }, onDraft: { _, _ in },
            onBlock: { block, _ in await capture.publish(block) })
        #expect(await resumed.calls == 1)
        #expect(await capture.blocks.map { $0.block.id } == plan.blocks.map(\.id))
    }
}

@Test func simpleRecoveryStillRejectsDuplicatedOrMissingSources() async throws {
    let capture = RecoveryResult()
    let transport = RecoveryTransport(duplicatePlan: true)
    await #expect(throws: AIReflowFailure.invalidStructure) {
        try await ModelClient(transport: transport).recoverReflowAndTranslate(
            sources: [TextBlock(sourcePage: 0, text: "One."), TextBlock(sourcePage: 0, text: "Two.")],
            title: "Fixture", settings: recoverySettings(), key: "fixture-only", acceptedPlan: nil,
            committedPlanBlockIDs: [],
            onPlan: { await capture.accept($0) }, onDraft: { _, _ in },
            onBlock: { block, _ in await capture.publish(block) })
    }
    #expect(await capture.plan == nil)
    #expect(await capture.blocks.isEmpty)
    #expect(await transport.calls == 1)
}

private func recoverySettings() -> ModelSettings {
    var settings = ModelSettings()
    settings.model = "fixture"
    return settings
}
