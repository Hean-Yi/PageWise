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
        root: root, client: ModelClient(transport: FakeModelTransport()), credentials: WorkflowCredentials())
    await model.load()
    await model.addDemo()
    let paper = try #require(model.paper)
    #expect(paper.canReflow)
    #expect(paper.previewPages.isEmpty)
    let firstURL = root.appendingPathComponent(paper.originalPath)
    let bytes = try Data(contentsOf: firstURL)
    let ids = await model.importURLs([root.appendingPathComponent(paper.originalPath)])
    #expect(ids == [paper.id])
    #expect(model.state.papers.count == 1)
    var settings = model.modelSettings
    settings.model = "test"
    try model.saveSettings(settings, key: nil)
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

@Test @MainActor func structuredTranslationRetainsOnlyOriginalAndFinalPagesAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: FakeModelTransport()), credentials: WorkflowCredentials())
    await model.load()
    let source = root.appendingPathComponent("demo.pdf")
    try DemoPaper.write(to: source)
    let original = try Data(contentsOf: source)
    let extracted = try PDFProcessor.extract(from: source)
    let html =
        "<article class='ltx_document'>" + extracted.blocks.map { "<p>\(HTMLPaperParser.escape($0.text))</p>" }.joined()
        + "</article>"
    let blocks = try await HTMLPaperParser().parse(
        Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    await model.importURLs([source], structuredBlocks: blocks)
    #expect(model.paper?.blocks.contains { $0.richContent != nil } == true)
    #expect(model.paper?.previewPages.isEmpty == true)
    var settings = model.modelSettings
    settings.model = "test"
    try model.saveSettings(settings, key: nil)
    model.startTranslation()
    for _ in 0..<2_000 {
        if model.translating.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.translating.isEmpty)
    let paper = try #require(model.paper)
    #expect(paper.translatedBlockCount == blocks.count)
    #expect(paper.blocks.allSatisfy { $0.richContent == nil })
    #expect(paper.previewPages.isEmpty)
    let expected = Set(
        ["original.pdf"]
            + paper.translatedPages.map { "translated/" + URL(fileURLWithPath: $0.relativePath).lastPathComponent })
    let paperRoot = root.appendingPathComponent(paper.originalPath).deletingLastPathComponent()
    let enumerator = try #require(
        FileManager.default.enumerator(at: paperRoot, includingPropertiesForKeys: [.isRegularFileKey]))
    var actual: Set<String> = []
    for url in enumerator.allObjects.compactMap({ $0 as? URL })
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        actual.insert(
            String(url.resolvingSymlinksInPath().path.dropFirst(paperRoot.resolvingSymlinksInPath().path.count + 1)))
    }
    #expect(actual == expected)
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
    let ids = paper.translatedPages.map(\.id)
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(reopened.state.papers[0].translatedPages.map(\.id) == ids)
    #expect(reopened.state.papers[0].blocks.allSatisfy { $0.richContent == nil })
}

@Test(arguments: ["unused", "highlight", "ink", "bookmark"])
@MainActor func completedLegacyPreviewCleanupPreservesUserAnchors(protection: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var paper = Paper(
        title: "Legacy", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Original text")], warnings: [], canReflow: true)
    let prefix = "Papers/\(paper.id.uuidString)"
    let preview = PageArtifact(
        blockIDs: [paper.blocks[0].id], sourcePage: 0,
        relativePath: prefix + "/preview/\(UUID().uuidString)-\(UUID().uuidString)-0001.pdf")
    paper.previewPages = [preview]
    paper.translatedPages = [
        PageArtifact(
            blockIDs: [paper.blocks[0].id], sourcePage: 0,
            relativePath: prefix + "/translated/text-\(UUID().uuidString)-0001.pdf")
    ]
    paper.translatedBlockCount = 1
    var state = LibraryState()
    state.papers = [paper]
    let previewURL = root.appendingPathComponent(preview.relativePath)
    try FileManager.default.createDirectory(
        at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original immutable bytes".utf8).write(to: previewURL)
    if protection == "highlight" {
        state.highlights = [
            Highlight(
                paperID: paper.id, pageKey: preview.id.uuidString, pageIndex: 0, text: "Original",
                rects: [[1, 2, 3, 4]])
        ]
    } else if protection == "bookmark" {
        state.bookmarks = [
            PageBookmark(paperID: paper.id, pageKey: preview.id.uuidString, pageIndex: 0, mode: "reflow")
        ]
    } else if protection == "ink" {
        let directory = root.appendingPathComponent(prefix + "/Ink")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ink bytes".utf8).write(to: directory.appendingPathComponent(preview.id.uuidString + ".drawing"))
    }
    try await LibraryStore(directory: root).save(state)
    let model = try ReaderModel(root: root)
    await model.load()
    #expect(model.state.papers[0].previewPages.isEmpty == (protection == "unused"))
    #expect(FileManager.default.fileExists(atPath: previewURL.path) == (protection != "unused"))
    let stored = try await LibraryStore(directory: root).load()
    #expect(stored.papers[0].previewPages == model.state.papers[0].previewPages)
}
