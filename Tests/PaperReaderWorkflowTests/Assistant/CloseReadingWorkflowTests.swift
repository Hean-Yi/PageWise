import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

private let comparisonText = "我的 attention 实验笔记：比较两种 masking 策略时，还需要对齐输入。"
private let closeReadingSources: [(dimension: CloseReadingDimension, quote: String)] = [
    (.thesis, "The output is a weighted mixture of values."),
    (.concept, "The question you are trying to answer becomes the query."),
    (.evidence, "An attention weight is part of a computation."),
    (.rebuttal, "A useful explanation should be checked against the actual inputs and outputs."),
    (.method, "Check which positions may interact and which are masked."),
]

private func notebookHeading(_ kind: String) -> String {
    switch kind {
    case "question": "为什么要跟踪输入？"
    case "thesis": "加权混合能说明什么？"
    case "evidence": "如何检查输出是否符合解释？"
    case "rebuttal": "什么观察会动摇结论？"
    default: "哪些限制值得带走？"
    }
}

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
        let readingNotes: [Passage]
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
        if body.messages.first?.content.contains("最终综合") == true {
            struct Inputs: Decodable {
                struct Lead: Decodable {
                    let id: String
                    let kind: String
                    let sources: [String]
                }
                let annotations: [Lead]
                let outlineEvidence: [Lead]
            }
            let input = try JSONDecoder().decode(Inputs.self, from: Data(payload.utf8))
            let sections: [[String: Any]] = input.outlineEvidence.map { lead in
                [
                    "heading": notebookHeading(lead.kind), "markdown": "从给定输入追踪关键操作。\n\n> 尚待核查的是对照条件是否一致。",
                    "sources": lead.sources,
                ]
            }
            return try response(["keep": input.annotations.map(\.id), "sections": sections], to: request)
        }
        let input = try JSONDecoder().decode(Window.self, from: Data(payload.utf8))
        let comparison = try #require(input.readingNotes.first { $0.anchorText.contains(comparisonText) })
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
                "analysis": item.quote + " 此前对照实验的笔记提出了核对输入条件的问题。", "references": [reference],
            ])
            stages.append([
                "stage": CloseReadingStage.allCases[index].rawValue, "text": "这一环节给出了核对原文的依据。",
                "references": [["source": passage.source, "quote": quote, "label": "当前论文原文"]],
            ])
        }
        await onRequest?()
        return try response(["annotations": output == .outlineOnly ? [] : annotations, "outline": stages], to: request)
    }

    private func response(_ object: [String: Any], to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
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
    try AttentionFixture.write(to: file)
    let id = try #require(await reader.importURLs([file]).first)
    let block = TextBlock(sourcePage: -1, text: "This attention benchmark measures masking policies.")
    var other = Paper(
        title: "Attention benchmark", digest: "comparison-fixture", originalPath: "other.pdf",
        pageCount: 1, blocks: [block], warnings: [], canReflow: true)
    other.htmlReading = try await HTMLReadingStore().append(
        [.init(block: block, translation: nil)], to: nil, paper: other, root: root)
    try #require(await reader.save(adding: other))
    reader.select(other.id)
    let scope = try reader.discussionNoteScope(for: other.id)
    let anchor = Evidence(id: "primary", title: other.title, text: block.text, paperID: other.id, blockID: block.id)
    _ = try await reader.saveDiscussionNote(
        in: scope, sources: [(anchor, block.text)], markdown: comparisonText, requestID: UUID())
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
    #expect(overview.markdown.contains("> 尚待核查"))
    for stage in CloseReadingStage.allCases {
        #expect(overview.markdown.contains("## " + notebookHeading(stage.rawValue)))
    }
    let ids = try #require(report.closeReadingNoteIDs)
    #expect(Set(ids).count == 5 && snapshot.readingNotes.count == 7)
    let notes = try ids.map { id in try #require(snapshot.readingNotes.first { $0.id == id }) }
    #expect(notes.compactMap(\.dimension) == CloseReadingDimension.allCases)
    #expect(Set(notes.compactMap { $0.anchors.first?.key }) == ["original-0", "original-1"])
    for (note, item) in zip(notes, closeReadingSources) {
        #expect(note.citations?.allSatisfy { $0.readingNoteID != nil } == true)
        let anchor = try #require(note.anchors.first)
        #expect(
            snapshot.highlights.contains {
                $0.paperID == id && $0.pageKey == anchor.key && $0.color == item.dimension.color
                    && $0.text == anchor.text
            })
        let citation = try #require(note.citations?.first { $0.paperID == comparison.id })
        #expect(note.markdown.contains(citation.url.absoluteString))
        let preview = try await reader.previewLocalPassage(noteID: note.id, citationID: citation.id)
        #expect(
            preview.noteMarkdown == comparisonText && preview.title == comparison.title && reader.selectedPaperID == id)
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
    #expect(await api.requests == 2)
    #expect(reopened.id == report.id && reopened.closeReadingNoteIDs == ids)
    #expect(
        restored.currentReadingNotes.count == 6
            && restored.currentHighlights.count == snapshot.highlights.filter { $0.paperID == id }.count)
    let retained = try #require(restored.currentReadingNotes.first { $0.id == edited.id })
    #expect(retained.markdown == revised && retained.anchors == edited.anchors && retained.dimension == .method)
    let target = try #require(retained.citations?.first { $0.paperID == comparison.id })
    let preview = try await restored.previewLocalPassage(noteID: retained.id, citationID: target.id)
    try await restored.openLocalPassage(preview)
    #expect(restored.selectedPaperID == comparison.id && restored.requestedReadingNote == target.readingNoteID)
}

@Test @MainActor func closeReadingWorkflowSavesAnOutlineWithVerifiedSourcesWhenThereAreNoParagraphNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: CloseReadingTransport(.outlineOnly))
    let report = try await reader.runCloseReading(id)
    let disk = try await reader.store.load()
    let overview = try #require(disk.readingNotes.first { $0.id == report.readingNoteID })
    #expect(disk.chats.map(\.id) == [report.id] && report.readingNoteID == overview.id)
    #expect(disk.readingNotes.count == 2 && overview.dimension == nil && (report.closeReadingNoteIDs ?? []).isEmpty)
    let citations = try #require(overview.citations)
    #expect(Set(citations.map(\.quote)) == Set(closeReadingSources.map(\.quote)))
    #expect(citations.allSatisfy { $0.paperID == id })
    #expect(overview.isDocumentSummary && overview.anchors.isEmpty)
    #expect(disk.highlights.allSatisfy { $0.paperID != id })
    #expect(reader.currentDocumentSummary?.id == overview.id)
    #expect(reader.inlineReadingNotes.isEmpty)
    #expect(reader.updateDocumentSummary(id: overview.id, markdown: overview.markdown + "\n\n个人补充。"))
    await reader.flushReadingNotes()
    #expect(
        try await reader.store.load().readingNotes.first { $0.id == overview.id }?.markdown.hasSuffix("个人补充。") == true)
    for stage in CloseReadingStage.allCases {
        #expect(overview.markdown.contains("## " + notebookHeading(stage.rawValue)))
    }
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
    #expect(
        await api.requests == (failure == .rejectedSave ? 2 : 1) && !reader.busyAI && reader.closeReadingTask == nil)
    let disk = try await reader.store.load()
    for snapshot in [reader.state, disk] {
        #expect(
            snapshot.readingNotes.filter { $0.paperID == id }.isEmpty
                && snapshot.highlights.filter { $0.paperID == id }.isEmpty && snapshot.chats.isEmpty)
    }
}

@Test @MainActor func rerunningSameFocusKeepsEditsAndDoesNotRestoreDeletedPassageNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = CloseReadingTransport()
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: api)
    let first = try await reader.runCloseReading(id, focus: "实验")
    let notes = try #require(first.closeReadingNoteIDs)
    let edited = try #require(reader.currentReadingNotes.first { $0.id == notes.first })
    let removed = try #require(notes.last)
    let markIndex = try #require(reader.state.highlights.firstIndex { $0.paperID == id })
    reader.state.highlights[markIndex].color = .purple
    let originalMarks = reader.currentHighlights
    let revised = edited.markdown + "\n\n我重新核对过这段原文。"
    let citation = try #require(edited.citations?.first)
    reader.openReadingNote(edited)
    try #require(reader.updateReadingNote(id: edited.id, anchors: edited.anchors, markdown: revised))
    reader.deleteReadingNote(removed)
    await reader.flushReadingNotes()
    let next = try await reader.runCloseReading(id, regenerate: true)
    let kept = try #require(next.closeReadingNoteIDs)
    #expect(
        first.id != next.id && first.question == next.question && kept.contains(edited.id) && !kept.contains(removed))
    #expect(reader.currentReadingNotes.first { $0.id == edited.id }?.markdown == revised)
    #expect(!reader.inlineReadingNotes.contains { $0.id == removed })
    #expect(reader.existingCloseReading(for: id)?.id == next.id && reader.state.chats.count == 2)
    let restored = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await restored.load()
    restored.select(id)
    #expect(restored.currentHighlights.map(\.id) == originalMarks.map(\.id))
    #expect(restored.currentHighlights.map(\.color) == originalMarks.map(\.color))
    #expect(restored.currentReadingNotes.first { $0.id == edited.id }?.markdown == revised)
    #expect(try await restored.previewLocalPassage(noteID: edited.id, citationID: citation.id).quote == comparisonText)
    #expect(!restored.currentReadingNotes.contains { $0.id == removed })
    reader.undoReadingNoteDeletion()
    await reader.flushReadingNotes()
    #expect(reader.inlineReadingNotes.contains { $0.id == removed })
    #expect(try await reader.store.load().readingNotes.first { $0.id == removed }?.deletedAt == nil)
    #expect(await api.requests == 4)
}

@Test @MainActor func libraryNotebookReopensAndEditsAHistoricalSummaryThenShowsItsOriginalPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: CloseReadingTransport(.outlineOnly))
    let first = try await reader.runCloseReading(id, focus: "实验")
    let next = try await reader.runCloseReading(id, focus: "方法")
    let persisted = try await reader.store.load()
    let notebook = try #require(PaperReadingNotebook.notebooks(in: persisted).first { $0.id == id })
    #expect(notebook.entries.map(\.id) == [next.id, first.id])
    let historical = try #require(notebook.entries.last?.note)
    reader.select(nil)
    reader.selectedSection = "notebooks"
    reader.select(historical.paperID)
    reader.openReadingNote(historical)
    #expect(reader.presentedDocumentSummary?.id == first.readingNoteID)
    let markdown = historical.markdown + "\n\n核对了 $x^2$。"
    #expect(reader.updateDocumentSummary(id: historical.id, markdown: markdown))
    await reader.flushReadingNotes()
    let edited = try await reader.store.load()
    #expect(PaperReadingNotebook.notebooks(in: edited).first?.entries.last?.note.markdown == markdown)
    reader.showOriginalReading()
    #expect(reader.presentedDocumentSummary == nil && reader.mode == "original" && reader.selectedPaperID == id)
    reader.returnFromReader()
    #expect(reader.selectedSection == "notebooks")
    await reader.flushReadingPosition()
}

@Test @MainActor func explicitPaperSummarySavesClickableSourcesWithoutMarkingAParagraph() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (reader, id, _) = try await closeReadingLibrary(root: root, api: CloseReadingTransport())
    let scope = try reader.discussionNoteScope(for: id)
    let quote = closeReadingSources[0].quote
    let source = Evidence(id: "S1", title: "Fixture", text: quote, paperID: id, sourcePage: 0)
    let request = "把全文总结成笔记"
    let note = try await reader.saveDiscussionNote(
        in: scope, sources: [(source, quote)], markdown: "输出由各值加权形成。", requestID: UUID(), instruction: request)
    #expect(note.isDocumentSummary && note.anchors.isEmpty && reader.inlineReadingNotes.isEmpty)
    #expect(reader.currentHighlights.isEmpty)
    let citation = try #require(note.citations?.first)
    #expect(try await reader.previewLocalPassage(noteID: note.id, citationID: citation.id).quote == quote)
    let hit = try #require(try await reader.readingNoteEvidence(query: "加权", paperID: id).first)
    #expect(reader.jump(to: hit) && reader.requestedReadingNote == note.id)
}
