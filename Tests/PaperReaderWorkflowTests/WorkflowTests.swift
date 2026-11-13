import Foundation
import PaperReaderKit
import PaperReaderUI
import Testing

private struct FakeModelTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = Data(
            #"{"choices":[{"message":{"content":"这是供自动化验证使用的完整中文译文，不是实际模型结果。"},"finish_reason":"stop"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test @MainActor func localImportTranslationAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: FakeModelTransport()), keyProvider: { "test-only" })
    await model.load()
    await model.addDemo()
    let paper = try #require(model.paper)
    #expect(paper.canReflow)
    #expect(!paper.previewPages.isEmpty)
    let firstURL = root.appendingPathComponent(paper.previewPages[0].relativePath)
    let bytes = try Data(contentsOf: firstURL)
    let ids = await model.importURLs([root.appendingPathComponent(paper.originalPath)])
    #expect(ids == [paper.id])
    #expect(model.state.papers.count == 1)
    model.modelSettings.model = "test"
    model.startTranslation()
    for _ in 0..<500 {
        if model.translating.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.translating.isEmpty)
    #expect(model.paper?.translatedBlockCount == paper.blocks.count)
    #expect(model.paper?.translatedPages.isEmpty == false)
    #expect(try Data(contentsOf: firstURL) == bytes)
    model.captureSelection(text: "Attention", rects: [[56, 500, 100, 20]], page: 0)
    model.highlightSelection()
    await model.ask("这篇论文研究什么？")
    #expect(model.state.chats.count == 1)
    #expect(model.state.memories.count == 1)
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(reopened.state.papers.count == 1)
    #expect(reopened.state.highlights.count == 1)
    #expect(reopened.state.chats.count == 1)
    #expect(reopened.state.papers[0].translatedBlockCount == paper.blocks.count)
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
        root: root, client: ModelClient(transport: FakeModelTransport()), keyProvider: { "test-only" })
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
