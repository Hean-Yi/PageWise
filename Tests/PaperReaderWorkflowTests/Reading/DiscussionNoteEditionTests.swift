import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

@MainActor private func openDiscussionEdition(at root: URL, first: TextBlock) async throws -> (ReaderModel, Paper) {
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var paper = Paper(
        title: "Discussion edition", digest: "edition-fixture", originalPath: "original.pdf", pageCount: 2,
        blocks: [first], warnings: [], canReflow: true)
    paper.htmlReading = try await HTMLReadingStore().append(
        [BilingualBlock(block: first, translation: "首段译文。")], to: nil, paper: paper, root: root)
    paper.translatedBlockCount = 1
    try #require(await reader.save(adding: paper))
    reader.select(paper.id)
    reader.openRetainedReading(nil)
    return (reader, paper)
}

@Test @MainActor func libraryDiscussionRoutesPageEvidenceToThePublishedSourceOrOriginalPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = "Multiple attention heads can form several mixtures at once."
    let pdfOnly = "An attention weight is part of a computation."
    let block = TextBlock(sourcePage: -1, text: shared)
    let (reader, paper) = try await openDiscussionEdition(at: root, first: block)
    let original = root.appendingPathComponent(paper.originalPath)
    try AttentionFixture.write(to: original)
    let page = try PDFSentenceExtractor.extractPage(url: original, pageIndex: 1)
    reader.select(nil)
    let scope = try reader.discussionNoteScope(for: paper.id)
    func savePageQuote(_ quote: String) async throws -> ReadingNote {
        let sentence = try #require(page.sentences.first { $0.text.contains(quote) })
        let evidence = Evidence(id: "S1", title: paper.title, text: sentence.text, paperID: paper.id, sourcePage: 1)
        return try await reader.saveDiscussionNote(
            in: scope, sources: [(evidence, quote)], markdown: "讨论结论", requestID: UUID())
    }
    let sourceNote = try await savePageQuote(shared)
    #expect(
        sourceNote.anchors == [
            NoteAnchor(key: block.id.uuidString, target: "source", text: shared, start: 0, end: shared.utf16.count)
        ])
    let pdfNote = try await savePageQuote(pdfOnly)
    #expect(pdfNote.contentVersion == paper.digest + ":original-0")
    let pdfParts = try await PDFReadingNoteLocator().locate(quote: pdfOnly, pageIndex: 1, in: original)
    #expect(!pdfParts.isEmpty && pdfNote.anchors == pdfParts.map(\.anchor))
    #expect(reader.state.highlights.contains { $0.pageKey == block.id.uuidString && $0.htmlTarget == "source" })
    #expect(reader.state.highlights.contains { $0.pageKey == "original-1" && !$0.rects.isEmpty })
}

@Test @MainActor func discussionNoteSurvivesHTMLAppendAndKeepsCapturedSection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let quote = "Only this sentence is marked."
    let prefix = "Observation 🧪: "
    let first = TextBlock(sourcePage: 0, text: prefix + quote)
    let (reader, initial) = try await openDiscussionEdition(at: root, first: first)
    let scope = try reader.discussionNoteScope(for: initial.id)
    let captured = try #require(scope.htmlReading)
    #expect(scope.prefersHTML)

    let next = TextBlock(sourcePage: 1, text: "Published after the discussion started.")
    var publication = initial
    let appended = try await HTMLReadingStore().append(
        [BilingualBlock(block: next, translation: "追加段落。")], to: captured, paper: initial, root: root)
    publication.htmlReading = appended
    publication.blocks.append(next)
    publication.translatedBlockCount = 2
    try #require(await reader.save(publishingReflow: publication))
    #expect(appended.sections.map(\.id) == [first.id, next.id])
    #expect(captured.sections.first?.relativePath != appended.sections.first?.relativePath)
    try HTMLReadingStore.cleanup(root: root, paper: publication)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(captured.relativePath).path))

    let laterEvidence = Evidence(id: "S2", title: initial.title, text: next.text, paperID: initial.id, blockID: next.id)
    await #expect(throws: ReaderError.self) {
        try await reader.saveDiscussionNote(
            in: scope, sources: [(laterEvidence, next.text)], markdown: "尚未读到的段落", requestID: UUID())
    }
    let originalEvidence = Evidence(
        id: "S1", title: initial.title, text: first.text, paperID: initial.id, blockID: first.id)
    let note = try await reader.saveDiscussionNote(
        in: scope, sources: [(originalEvidence, quote)], markdown: "**讨论结论**", requestID: UUID())
    let end = prefix.utf16.count + quote.utf16.count
    #expect(note.contentVersion == initial.digest + ":" + first.id.uuidString)
    #expect(
        note.anchors == [
            NoteAnchor(key: first.id.uuidString, target: "source", text: quote, start: prefix.utf16.count, end: end)
        ])
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    #expect(reopened.state.readingNotes.map(\.id) == [note.id])
    #expect(reopened.state.readingNotes.first?.anchors == note.anchors)
    let marks = reopened.state.highlights
    #expect(marks.count == 1)
    let mark = try #require(marks.first)
    #expect(mark.pageKey == first.id.uuidString && mark.pageIndex == 0 && mark.htmlTarget == "source")
    #expect(mark.text == quote && mark.textRange == [prefix.utf16.count, end])
}

@Test @MainActor func discussionNoteRejectsAmbiguousQuotesAndReplacedHTMLEditionsAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let unique = "A unique finding."
    let repeated = "Repeated wording."
    let first = TextBlock(sourcePage: 0, text: [unique, repeated, repeated].joined(separator: " "))
    let (reader, initial) = try await openDiscussionEdition(at: root, first: first)
    let scope = try reader.discussionNoteScope(for: initial.id)
    let evidence = Evidence(id: "S1", title: initial.title, text: first.text, paperID: initial.id, blockID: first.id)
    await #expect(throws: ReaderError.self) {
        try await reader.saveDiscussionNote(
            in: scope, sources: [(evidence, unique), (evidence, repeated)], markdown: "两处证据", requestID: UUID())
    }

    // Keep the original paragraph and its ID in the replacement edition to catch accidental relocation.
    let addedFirst = TextBlock(sourcePage: 0, text: "Preface to the new edition.")
    var replacement = initial
    replacement.blocks = [addedFirst, first]
    replacement.htmlReading = try await HTMLReadingStore().append(
        replacement.blocks.map { BilingualBlock(block: $0, translation: "新版译文。") }, to: nil, paper: replacement,
        root: root)
    replacement.translatedBlockCount = 2
    try #require(await reader.save(publishingReflow: replacement))
    await #expect(throws: ReaderError.self) {
        try await reader.saveDiscussionNote(
            in: scope, sources: [(evidence, unique)], markdown: "旧版结论", requestID: UUID())
    }
    #expect(reader.state.readingNotes.isEmpty && reader.state.highlights.isEmpty)
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    #expect(reopened.state.readingNotes.isEmpty && reopened.state.highlights.isEmpty)
}

@Test @MainActor func manualHTMLNoteStaysVisibleAfterAppendAndReopensItsRetainedEdition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = TextBlock(sourcePage: 0, text: "The same paragraph appears in both editions.")
    let (reader, initial) = try await openDiscussionEdition(at: root, first: first)
    let anchor = NoteAnchor(
        key: first.id.uuidString, target: "source", text: first.text, start: 0, end: first.text.utf16.count)
    let id = UUID()
    try #require(reader.updateReadingNote(id: id, anchors: [anchor], markdown: "手工笔记"))
    await reader.flushReadingNotes()
    let manual = try #require(reader.displayedHTMLReadingNotes.first)
    #expect(manual.id == id && manual.contentVersion == initial.digest + ":" + first.id.uuidString)

    let store = HTMLReadingStore()
    let second = TextBlock(sourcePage: 1, text: "An appended paragraph.")
    var expanded = initial
    expanded.htmlReading = try await store.append(
        [BilingualBlock(block: second, translation: "追加段落。")], to: initial.htmlReading, paper: expanded, root: root)
    expanded.blocks.append(second)
    expanded.translatedBlockCount = 2
    try #require(await reader.save(publishingReflow: expanded))
    #expect(reader.displayedHTMLReadingNotes.map(\.id) == [id])

    let retained = RetainedReading(paper: expanded)
    var replacement = expanded
    replacement.retainedReadings = [retained]
    replacement.blocks = [second, first]
    replacement.htmlReading = try await store.append(
        replacement.blocks.map { BilingualBlock(block: $0, translation: "新版译文。") }, to: nil, paper: replacement,
        root: root)
    try #require(await reader.save(publishingReflow: replacement))
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    reopened.select(initial.id)
    reopened.openRetainedReading(nil)
    #expect(reopened.displayedHTMLReadingNotes.isEmpty)
    let saved = try #require(reopened.currentReadingNotes.first)
    reopened.openReadingNote(saved)
    #expect(reopened.retainedReadingID == retained.id && reopened.mode == "translated")
    #expect(reopened.visiblePage == 0 && reopened.requestedReadingNote == id)
    #expect(reopened.displayedHTMLReadingNotes.map(\.id) == [id])

    reopened.openRetainedReading(nil)
    var unavailable = saved
    unavailable.contentVersion = initial.digest + ":" + UUID().uuidString
    let previousToken = reopened.readingNoteNavigationToken
    reopened.openReadingNote(unavailable)
    #expect(reopened.retainedReadingID == nil && reopened.readingNoteNavigationToken == previousToken)
}
