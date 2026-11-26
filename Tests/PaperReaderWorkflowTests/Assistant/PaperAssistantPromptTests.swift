import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

private actor OversizedPromptTransport: HTTPTransport {
    private(set) var requestBytes: [Int] = []
    private(set) var requestBodies: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestBytes.append(request.httpBody?.count ?? 0)
        requestBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let body = #"{"choices":[{"message":{"content":"{\"memory\":\"\"}"},"finish_reason":"stop"}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        requestBytes.append(request.httpBody?.count ?? 0)
        requestBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let event = #"{"choices":[{"delta":{"content":"这段原文讨论对照条件 [S1]。"},"finish_reason":"stop"}]}"#
        try await onData(Data(("data: " + event + "\n\ndata: [DONE]\n\n").utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func oversizedPaperSelectionIsTrimmedBeforeTheFirstRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = OversizedPromptTransport()
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("oversized.pdf")
    try AttentionFixture.write(to: file)
    let paperID = try #require(await reader.importURLs([file]).first)
    reader.select(paperID)
    reader.captureSelection(
        text: String(repeating: "关键证据与对照条件。", count: 4_000), rects: [], page: 0)
    await reader.ask("请解释这段原文的意思。")
    let turn = try #require(reader.state.chats.last)
    #expect(!turn.answer.isEmpty)
    let sizes = await transport.requestBytes
    #expect(!sizes.isEmpty)
    // The request body includes JSON overhead plus tool schemas. The hard budget is 80 KB, so a
    // little envelope headroom is expected; an untrimmed Chinese prompt would exceed 120 KB.
    #expect(sizes.allSatisfy { $0 <= 96_000 })
    let bodies = await transport.requestBodies
    #expect(!bodies.contains { $0.contains("读者背景（非学术证据）：") })
}

private actor ScriptedPaperToolTransport: HTTPTransport {
    private let streamResponses: [String]
    private var streamIndex = 0
    private(set) var dataCallCount = 0

    init(_ streamResponses: [String]) {
        self.streamResponses = streamResponses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        dataCallCount += 1
        let body = #"{"choices":[{"message":{"content":"{\"memory\":\"\"}"},"finish_reason":"stop"}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        let payload = streamResponses[min(streamIndex, streamResponses.count - 1)]
        streamIndex += 1
        try await onData(Data(payload.utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func paperAssistantRunsReadOnlyToolBatchConcurrentlyAndPreservesCitationOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attention.pdf")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: file)
    let paper = Paper(
        title: "Understanding Attention", digest: "batch-concurrent", originalPath: "attention.pdf", pageCount: 2,
        blocks: [
            TextBlock(sourcePage: 0, text: "Page one introduces attention weights."),
            TextBlock(sourcePage: 1, text: "Page two warns that weights alone do not prove causality."),
        ], warnings: [], canReflow: true)
    let note = ReadingNote(
        paperID: paper.id, contentVersion: "v", anchors: [],
        markdown: "读者手记：关于 causal attribution 需要额外消融实验。")
    let readArgs = #"{\"paper_id\":\"\#(paper.id.uuidString)\",\"source_page\":2}"#
    let noteArgs = #"{\"query\":\"causal attribution\"}"#
    let round1 =
        "data: "
        + #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_read","type":"function","function":{"name":"read_paper","arguments":"\#(readArgs)"}},{"index":1,"id":"call_notes","type":"function","function":{"name":"search_reading_notes","arguments":"\#(noteArgs)"}}]},"finish_reason":"tool_calls"}]}"#
        + "\n\ndata: [DONE]\n\n"
    let round2 =
        "data: "
        + #"{"choices":[{"delta":{"content":"第二页指出权重本身不能证明因果 [S3]，此前笔记也提到需要消融 [S4]。"},"finish_reason":"stop"}]}"#
        + "\n\ndata: [DONE]\n\n"
    let transport = ScriptedPaperToolTransport([round1, round2])
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    reader.state.papers = [paper]
    reader.state.readingNotes = [note]
    _ = await reader.save()
    reader.select(paper.id)

    await reader.ask("请核对第 2 页和我的笔记。")
    let turn = try #require(reader.state.chats.last)
    #expect(turn.answer.contains("[S3]"))
    #expect(turn.answer.contains("[S4]"))
    #expect(turn.evidence.contains { $0.id == "S3" && $0.sourcePage == 1 })
    #expect(turn.evidence.contains { $0.id == "S4" && $0.readingNoteID == note.id })
}

@Test @MainActor func paperAssistantProposesMemoryThroughToolWithoutExtraExtractionAndLinksTurnForRevocation()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("proposal.pdf")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: file)
    let question = "我接下来打算长期比较等算力下的蒸馏与剪枝效果，这篇方法符合等算力设定吗？"
    let proposeArgs =
        #"{\"statement\":\"长期比较等算力下的蒸馏与剪枝效果\",\"quote\":\"我接下来打算长期比较等算力下的蒸馏与剪枝效果\"}"#
    let round1 =
        "data: "
        + #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_mem","type":"function","function":{"name":"propose_memory","arguments":"\#(proposeArgs)"}}]},"finish_reason":"tool_calls"}]}"#
        + "\n\ndata: [DONE]\n\n"
    let round2 =
        "data: "
        + #"{"choices":[{"delta":{"content":"文中仅说明了注意力机制示例，未给出等算力对照 [S1]。"},"finish_reason":"stop"}]}"#
        + "\n\ndata: [DONE]\n\n"
    let transport = ScriptedPaperToolTransport([round1, round2])
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let paperID = try #require(await reader.importURLs([file]).first)
    reader.select(paperID)

    await reader.ask(question)
    let turn = try #require(reader.state.chats.last)
    let memory = try #require(reader.state.memories.first { !$0.deleted && $0.text.contains("蒸馏与剪枝") })
    #expect(memory.sourceID == turn.id)
    #expect(await transport.dataCallCount == 0)
    #expect(turn.backgroundSources?.memoryIDs.contains(memory.id) == true)

    reader.deleteMemory(memory.id)
    let refreshed = try #require(reader.state.chats.first { $0.id == turn.id })
    #expect(refreshed.backgroundSources?.isCurrent(in: reader.state, excluding: []) == false)
}
