import Foundation
import PDFKit
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

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
    #expect(await model.openBundledSample() == nil)
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
    #expect(model.lastAssistantFailure?.message.contains("没有可读取的文字") == true)
    #expect(model.message == nil)
}

@Test @MainActor func importedPDFAnswersWithSelectedOrVisibleOriginalPageCitations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: FakeModelTransport()), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let pdf = root.appendingPathComponent("example.pdf")
    try AttentionFixture.write(to: pdf)
    let id = try #require(await model.importURLs([pdf]).first)
    #expect(model.paper?.blocks.isEmpty == true)
    model.recordVisiblePage(1)
    await model.ask("What does this page say?")
    let page = try #require(model.state.chats.last?.evidence.first)
    #expect(page.paperID == id && page.sourcePage == 1 && page.id == "S1")
    #expect(page.text.contains("identify the source"))
    #expect(!page.text.contains("Imagine a notebook"))

    let selected = "Imagine a notebook containing observations about several experiments."
    model.captureSelection(text: selected, rects: [], page: 0)
    await model.ask("Explain the selected text")
    let excerpt = try #require(model.state.chats.last?.evidence.first)
    #expect(excerpt.text == selected && excerpt.paperID == id && excerpt.sourcePage == 0 && excerpt.blockID == nil)
    model.jump(to: excerpt)
    #expect(model.visiblePage == 0)
    model.clearAssistantSelection()
    #expect(model.openBilingualReading(translatingDocument: false))
    model.pdfBilingual.prepareParagraphReading(model)
    for _ in 0..<500 where model.pdfBilingual.paragraphPages.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    let first = try #require(model.pdfBilingual.paragraphPages[0]?.sentences.first)
    let second = try #require(model.pdfBilingual.paragraphPages[1]?.sentences.first)
    model.selectBilingualSentences([first.id, second.id])
    #expect(model.assistantSelectionText == first.text + " " + second.text)
    await model.ask("Explain both sentences")
    let evidence = try #require(model.state.chats.last?.evidence)
    #expect(evidence.map(\.sourcePage) == [0, 1])
    #expect(evidence.map(\.text) == [first.text, second.text])
    model.captureSelection(text: selected, rects: [], page: 0)
    #expect(model.assistantSelectionText == selected)
    model.selectBilingualSentences([second.id])
    #expect(model.selectionText.isEmpty)
    model.clearAssistantSelection()
    #expect(model.assistantSelectionText.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func quickStartReopensTheInstalledSampleAfterRelaunch(existingPaper: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var otherID: UUID?
    if existingPaper {
        let url = root.appendingPathComponent("personal.pdf")
        try AttentionFixture.write(to: url)
        let importedID: UUID = try #require(await reader.importURLs([url]).first)
        #expect(reader.selectedPaperID == importedID)
        otherID = importedID
    }
    let sampleID = try #require(await reader.openBundledSample())
    let first = try #require(reader.paper)
    #expect(sampleID == first.id && sampleID != otherID && first.pageCount == 2 && reader.mode == "original")
    let imported = root.appendingPathComponent(first.originalPath)
    #expect(try Data(contentsOf: DemoPaper.fileURL()) == Data(contentsOf: imported))
    let page = try #require(PDFDocument(url: imported)?.page(at: 0)?.string as NSString?)
    let quote = "A higher average can hide a weaker result in every group."
    let range = page.range(of: quote)
    try #require(range.location != NSNotFound)
    reader.captureSelection(text: quote, rects: [], page: 0, ranges: [range])
    await reader.beginPDFReadingNote()
    let draft = try #require(reader.pdfNoteEditor)
    #expect(reader.updateReadingNote(id: draft.id, anchors: draft.note.anchors, markdown: "示例批注"))
    await reader.flushReadingNotes()
    await reader.flushReadingPosition()
    let next = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await next.load()
    next.select(otherID)
    #expect(await next.openBundledSample() == sampleID)
    #expect(next.selectedPaperID == sampleID)
    #expect(next.state.papers.count == (existingPaper ? 2 : 1))
    let saved = try #require(next.currentReadingNotes.first)
    #expect(saved.id == draft.id && saved.anchors == draft.note.anchors && saved.markdown == "示例批注")
}
