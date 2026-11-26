import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

private actor OversizedPromptTransport: HTTPTransport {
    private(set) var requestBytes: [Int] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestBytes.append(request.httpBody?.count ?? 0)
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
}
