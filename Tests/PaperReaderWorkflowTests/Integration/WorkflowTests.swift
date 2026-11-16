import Foundation
import PaperReaderKit
import PaperReaderUI
import Testing

private struct FakeModelTransport: HTTPTransport {
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        let text = "这是原创测试回答。"
        let event: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        try await onData(Data(("data: " + json + "\n\ndata: [DONE]\n\n").utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = Data(
            #"{"choices":[{"message":{"content":"这是供自动化验证使用的完整中文译文，不是实际模型结果。"},"finish_reason":"stop"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test @MainActor func failedLibraryWriteDoesNotReportSuccessfulImport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let db = root.appendingPathComponent("library.sqlite")
    try FileManager.default.removeItem(at: db)
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: false)
    await model.addDemo()
    #expect(model.state.papers.isEmpty)
    #expect(model.message != nil)
    #expect(model.status.contains("未保存"))
}

@Test @MainActor func scannedPaperCannotBeAnsweredFromOtherPapersAlone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: FakeModelTransport()), credentials: WorkflowCredentials())
    await model.load()
    let scanned = Paper(
        title: "Scan", digest: "scan", originalPath: "scan.pdf", pageCount: 1, blocks: [], warnings: ["No text"],
        canReflow: false)
    let other = Paper(
        title: "Other", digest: "other", originalPath: "other.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "attention mechanism")], warnings: [], canReflow: true)
    model.state.papers = [scanned, other]
    model.select(scanned.id)
    await model.ask("attention")
    #expect(model.state.chats.isEmpty)
    #expect(model.message?.contains("没有可读取的文字") == true)
}
