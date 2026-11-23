import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private let comparisonText = "An attention benchmark compared matched inputs under different masking rules."
private let closeReadingSources: [(dimension: CloseReadingDimension, quote: String)] = [
    (.thesis, "The output is a weighted mixture of values."),
    (.concept, "The question you are trying to answer becomes the query."),
    (.evidence, "An attention weight is part of a computation."),
    (.rebuttal, "A useful explanation should be checked against the actual inputs and outputs."),
    (.method, "Check which positions may interact and which are masked."),
]

private actor CloseReadingTransport: HTTPTransport {
    private struct Request: Decodable {
        struct Message: Decodable { let content: String }
        let messages: [Message]
    }
    private struct Window: Decodable {
        struct Passage: Decodable {
            let source: String
            let anchorText: String
        }
        let passages: [Passage]
        let comparisons: [Passage]
    }

    enum Output { case annotated, outlineOnly, inventedQuotes }
    private let output: Output
    private(set) var requests = 0
    private var onRequest: (@MainActor @Sendable () -> Void)?

    init(_ output: Output = .annotated) { self.output = output }

    func setOnRequest(_ action: @escaping @MainActor @Sendable () -> Void) { onRequest = action }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let body = try JSONDecoder().decode(Request.self, from: request.httpBody ?? Data())
        let payload = try #require(body.messages.last?.content)
        let input = try JSONDecoder().decode(Window.self, from: Data(payload.utf8))
        let comparison = try #require(input.comparisons.first { $0.anchorText.contains(comparisonText) })
        #expect(comparison.source == "L1" && input.passages.first?.source == "P1")
        var annotations: [[String: Any]] = []
        var stages: [[String: Any]] = []
        for (index, item) in closeReadingSources.enumerated() {
            let passage = try #require(input.passages.first { $0.anchorText.contains(item.quote) })
            let quote = output == .inventedQuotes ? "Invented quotation absent from both papers." : item.quote
            let reference = [
                "source": comparison.source, "label": "书库中的对照实验",
                "quote": output == .inventedQuotes ? "Unsupported comparison absent from both papers." : comparisonText,
            ]
            annotations.append([
                "dimension": item.dimension.rawValue, "source": passage.source, "quote": quote,
                "role": "界定作者在本段讨论的现象。", "explanation": "这里描述的是观察到的关系。",
                "critique": "需要对照条件才能分辨原因。", "references": [reference],
            ])
            stages.append([
                "stage": CloseReadingStage.allCases[index].rawValue, "text": "这一环节给出了核对原文的依据。",
                "references": [["source": passage.source, "quote": quote, "label": "当前论文原文"]],
            ])
        }
        await onRequest?()
        let data = try JSONSerialization.data(withJSONObject: [
            "annotations": output == .outlineOnly ? [] : annotations, "outline": stages,
        ])
        let content = String(decoding: data, as: UTF8.self)
        let url = try #require(request.url)
        return (
            try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content], "finish_reason": "stop"]]
            ]),
            try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        throw ReaderError.message("精读应使用结构化模型输出。")
    }
}

@MainActor private func closeReadingLibrary(root: URL, api: CloseReadingTransport) async throws -> (
    ReaderModel, UUID, Paper
) {
    let reader = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("attention.pdf")
    try DemoPaper.write(to: file)
    let id = try #require(await reader.importURLs([file]).first)
    let block = TextBlock(sourcePage: -1, text: comparisonText)
    var other = Paper(
        title: "Attention benchmark", digest: "comparison-fixture", originalPath: "other.pdf",
        pageCount: 1, blocks: [block], warnings: [], canReflow: true)
    other.htmlReading = try await HTMLReadingStore().append(
        [.init(block: block, translation: nil)], to: nil, paper: other, root: root)
    try #require(await reader.save(adding: other))
    reader.select(id)
    return (reader, id, other)
}

@Test @MainActor func closeReadingWorkflowSavesFiveColorsAndReopensTheEditedNotesWithLocalLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = CloseReadingTransport()
    let (reader, id, comparison) = try await closeReadingLibrary(root: root, api: api)
    let report = try await reader.runCloseReading(id)
    let snapshot = try await reader.store.load()
    #expect(snapshot.chats.map(\.id) == [report.id] && report.closeReadingVersion != nil)
    let overview = try #require(snapshot.readingNotes.first { $0.id == report.readingNoteID })
    #expect(overview.markdown.contains("全文论证骨架"))
    for stage in CloseReadingStage.allCases { #expect(overview.markdown.contains("**" + stage.title + "**")) }
    let ids = try #require(report.closeReadingNoteIDs)
    #expect(Set(ids).count == 5 && snapshot.readingNotes.count == 6)
    let notes = try ids.map { id in try #require(snapshot.readingNotes.first { $0.id == id }) }
    #expect(notes.compactMap(\.dimension) == CloseReadingDimension.allCases)
    #expect(Set(notes.compactMap { $0.anchors.first?.key }) == ["original-0", "original-1"])
    for (note, item) in zip(notes, closeReadingSources) {
        let original = try #require(note.citations?.first { $0.paperID == id })
        #expect(original.quote == item.quote && original.anchors == note.anchors)
        let anchor = try #require(note.anchors.first)
        #expect(
            snapshot.highlights.contains {
                $0.paperID == id && $0.pageKey == anchor.key && $0.color == item.dimension.color
                    && $0.text == anchor.text
            })
        let citation = try #require(note.citations?.first { $0.paperID == comparison.id })
        #expect(note.markdown.contains(citation.url.absoluteString))
        let preview = try await reader.previewLocalPassage(noteID: note.id, citationID: citation.id)
        #expect(preview.quote == comparisonText && preview.title == comparison.title && reader.selectedPaperID == id)
    }
    let edited = try #require(notes.last)
    reader.openReadingNote(edited)
    #expect(reader.visiblePage == 1 && reader.pdfNoteEditor?.id == edited.id)
    let revised = edited.markdown + "\n\n我核对了这个方法的适用范围。"
    try #require(reader.updateReadingNote(id: edited.id, anchors: edited.anchors, markdown: revised))
    await reader.flushReadingNotes()
    let restored = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await restored.load()
    restored.select(id)
    let reopened = try await restored.runCloseReading(id)
    #expect(await api.requests == 1)
    #expect(reopened.id == report.id && reopened.closeReadingNoteIDs == ids)
    #expect(restored.currentReadingNotes.count == 6 && restored.currentHighlights.count == snapshot.highlights.count)
    let retained = try #require(restored.currentReadingNotes.first { $0.id == edited.id })
    #expect(retained.markdown == revised && retained.anchors == edited.anchors && retained.dimension == .method)
    let target = try #require(retained.citations?.first { $0.paperID == comparison.id })
    let preview = try await restored.previewLocalPassage(noteID: retained.id, citationID: target.id)
    try await restored.openLocalPassage(preview)
    #expect(restored.selectedPaperID == comparison.id && restored.jumpPassageAnchors == target.anchors)
}

@Test @MainActor func closeReadingWorkflowSavesAnOutlineWithVerifiedSourcesWhenThereAreNoParagraphNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: CloseReadingTransport(.outlineOnly))
    let report = try await reader.runCloseReading(id)
    let disk = try await reader.store.load()
    let overview = try #require(disk.readingNotes.first)
    #expect(disk.chats.map(\.id) == [report.id] && report.readingNoteID == overview.id)
    #expect(disk.readingNotes.count == 1 && overview.dimension == nil && (report.closeReadingNoteIDs ?? []).isEmpty)
    let citations = try #require(overview.citations)
    #expect(Set(citations.map(\.quote)) == Set(closeReadingSources.map(\.quote)))
    #expect(citations.allSatisfy { $0.paperID == id })
    #expect(citations.contains { $0.anchors == overview.anchors })
    for stage in CloseReadingStage.allCases { #expect(overview.markdown.contains("**" + stage.title + "**")) }
    let source = try #require(citations.last)
    let preview = try await reader.previewLocalPassage(noteID: overview.id, citationID: source.id)
    #expect(preview.quote == source.quote)
}

private enum CloseReadingFailure: CaseIterable { case cancelled, inventedQuote, rejectedSave }

@Test(arguments: CloseReadingFailure.allCases) @MainActor
private func closeReadingWorkflowFailuresLeaveNoPartialNotesOrReport(
    _ failure: CloseReadingFailure
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = CloseReadingTransport(failure == .inventedQuote ? .inventedQuotes : .annotated)
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: api)
    switch failure {
    case .cancelled:
        await api.setOnRequest { reader.closeReadingTask?.cancel() }
        await #expect(throws: CancellationError.self) { try await reader.runCloseReading(id) }
    case .inventedQuote:
        await #expect(throws: ReaderError.self) { try await reader.runCloseReading(id) }
    case .rejectedSave:
        // Exercise the final transactional write after the source and all annotations have passed validation.
        reader.state.version = LibraryState.currentVersion + 1
        await #expect(throws: ReaderError.self) { try await reader.runCloseReading(id) }
    }
    #expect(await api.requests == 1 && !reader.busyAI && reader.closeReadingTask == nil)
    let disk = try await reader.store.load()
    for snapshot in [reader.state, disk] {
        #expect(snapshot.readingNotes.isEmpty && snapshot.highlights.isEmpty && snapshot.chats.isEmpty)
    }
}
