import CoreText
import Foundation
import PDFKit
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

@MainActor private func makeCitationLibrary(_ root: URL) async throws -> (ReaderModel, Paper, Paper) {
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let block = TextBlock(
        sourcePage: -1,
        text:
            "Baseline conditions required equal compute. The evidence supports a narrow conclusion. Future trials may differ."
    )
    var html = Paper(
        title: "Matched baselines", digest: "edition", originalPath: "primary.pdf", pageCount: 2, blocks: [block],
        warnings: [], canReflow: true)
    html.htmlReading = try await HTMLReadingStore().append(
        [BilingualBlock(block: block, translation: "原文译文。")], to: nil, paper: html, root: root)
    try AttentionFixture.write(to: root.appendingPathComponent(html.originalPath))
    let pdf = Paper(
        title: "Understanding Attention", digest: "attention", originalPath: "external.pdf", pageCount: 2, blocks: [],
        warnings: [], canReflow: false)
    try AttentionFixture.write(to: root.appendingPathComponent(pdf.originalPath))
    try #require(await reader.save(adding: html))
    try #require(await reader.save(adding: pdf))
    reader.select(html.id)
    reader.openRetainedReading(nil)
    return (reader, html, pdf)
}

@Test @MainActor func legacyLinksKeepTheirPersistedPDFRangeAndPaper() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, main, pdf) = try await makeCitationLibrary(root)
    let block = try #require(main.blocks.first)
    let noteID = UUID()
    let anchor = NoteAnchor(
        key: block.id.uuidString, target: "source", text: block.text, start: 0, end: block.text.utf16.count)
    #expect(model.updateReadingNote(id: noteID, anchors: [anchor], markdown: "我们讨论了适用范围。"))
    let quote = "An attention weight is part of a computation."
    let evidence = Evidence(id: "S1", title: pdf.title, text: quote, paperID: pdf.id, sourcePage: 1)
    let citation = try await model.makeLocalPassageCitation(evidence: evidence, quote: quote)
    let body = "我们讨论了适用范围。" + citation.markdown(label: "互证 [1]")
    let index = try #require(model.state.readingNotes.firstIndex { $0.id == noteID })
    // A pre-memory library linked raw passages directly, including passages from other papers.
    model.state.readingNotes[index].markdown = body
    model.state.readingNotes[index].citations = [citation]
    try #require(await model.save())
    let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await restored.load()
    restored.select(main.id)
    #expect(restored.currentReadingNotes.first?.citations == [citation])
    let preview = try await restored.previewLocalPassage(noteID: noteID, citationID: citation.id)
    #expect(preview.title == pdf.title && preview.location == "原文第 2 页")
    #expect(preview.quote.contains(quote) && !preview.after.isEmpty && restored.selectedPaperID == main.id)
    #expect(LocalPassageCitation.id(from: citation.url) == citation.id)
    for string in [
        "https://example.com/" + citation.id.uuidString, citation.url.absoluteString + "?source=other",
        "paperreader://passage/../" + citation.id.uuidString,
    ] {
        #expect(LocalPassageCitation.id(from: try #require(URL(string: string))) == nil)
    }
    let other = UUID()
    restored.openRetainedReading(nil)
    #expect(restored.updateReadingNote(id: other, anchors: [anchor], markdown: body))
    await #expect(throws: ReaderError.self) {
        try await restored.previewLocalPassage(noteID: other, citationID: citation.id)
    }
    try await restored.openLocalPassage(preview)
    #expect(restored.selectedPaperID == pdf.id && restored.mode == "original" && restored.visiblePage == 1)
    #expect(restored.jumpPassageAnchors == citation.anchors)
    restored.select(main.id)
    restored.state.papers.removeAll { $0.id == pdf.id }
    await #expect(throws: ReaderError.self) {
        try await restored.previewLocalPassage(noteID: noteID, citationID: citation.id)
    }
}

@Test @MainActor func localPassageLinksUseTheRetainedHTMLEditionAndRejectInventedOrUnregisteredText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, html, pdf) = try await makeCitationLibrary(root)
    let block = try #require(html.blocks.first)
    let quote = "The evidence supports a narrow conclusion."
    let evidence = Evidence(id: "S1", title: html.title, text: block.text, paperID: html.id, blockID: block.id)
    let citation = try await model.makeLocalPassageCitation(evidence: evidence, quote: quote)
    #expect(try await model.makeLocalPassageCitation(evidence: evidence, quote: quote) == citation)
    model.select(pdf.id)
    model.mode = "original"
    let origin = "An attention weight is part of a computation."
    let source = Evidence(id: "P1", title: pdf.title, text: origin, paperID: pdf.id, sourcePage: 1)
    let scope = try model.discussionNoteScope(for: pdf.id)
    let body = "与观察条件对照。" + citation.markdown(label: "样本边界")
    await #expect(throws: ReaderError.self) {
        try await model.saveDiscussionNote(in: scope, sources: [(source, origin)], markdown: body, requestID: UUID())
    }
    let invented = LocalPassageCitation(
        paperID: html.id, digest: html.digest, contentVersion: citation.contentVersion,
        anchors: citation.anchors, quote: "An invented experiment")
    await #expect(throws: ReaderError.self) {
        try await model.saveDiscussionNote(
            in: scope, sources: [(source, origin)], markdown: invented.markdown(label: "假文本"),
            requestID: UUID(), citations: [invented])
    }
    #expect(model.state.readingNotes.isEmpty && model.state.highlights.isEmpty)
    await #expect(throws: ReaderError.self) {
        try await model.saveDiscussionNote(
            in: scope, sources: [(source, origin)], markdown: body, requestID: UUID(), citations: [citation])
    }
    let note = try await model.saveDiscussionNote(
        in: scope, sources: [(source, origin)], markdown: "与观察条件对照。", requestID: UUID(), dimension: .evidence)
    let index = try #require(model.state.readingNotes.firstIndex { $0.id == note.id })
    model.state.readingNotes[index].markdown = body
    model.state.readingNotes[index].citations = [citation]
    #expect(note.dimension == .evidence && model.state.highlights.first?.color == .blue)
    let retained = RetainedReading(paper: html)
    let second = TextBlock(sourcePage: -1, text: "A distinct edition.")
    var replacement = html
    replacement.retainedReadings = [retained]
    replacement.blocks = [second, block]
    replacement.htmlReading = try await HTMLReadingStore().append(
        replacement.blocks.map { BilingualBlock(block: $0, translation: "新版。") },
        to: nil, paper: replacement, root: root)
    try #require(await model.save(publishingReflow: replacement))
    let preview = try await model.previewLocalPassage(noteID: note.id, citationID: citation.id)
    #expect(preview.before.contains("equal compute.") && preview.after.contains("Future trials"))
    try await model.openLocalPassage(preview)
    #expect(
        model.selectedPaperID == html.id && model.retainedReadingID == retained.id
            && model.jumpPassageAnchors == citation.anchors)
    #expect(model.state.highlights.allSatisfy { $0.paperID == pdf.id })
    model.select(pdf.id)
    model.state.papers[try #require(model.state.papers.firstIndex { $0.id == html.id })].retainedReadings = []
    await #expect(throws: ReaderError.self) {
        try await model.previewLocalPassage(noteID: note.id, citationID: citation.id)
    }
}

@Test @MainActor func recalledNoteCitationsFollowEditsRestartAndDeletionAndNeverSearchAnUnannotatedPaper() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, main, pdf) = try await makeCitationLibrary(root)
    #expect(try await model.readingNoteEvidence(query: "attention", excluding: main.id).isEmpty)
    let scope = try model.discussionNoteScope(for: pdf.id)
    let sentence = "An attention weight is part of a computation."
    let source = Evidence(id: "P1", title: pdf.title, text: sentence, paperID: pdf.id, sourcePage: 1)
    let observation = "模型的缓存预算相同才可以比较。"
    let target = try await model.saveDiscussionNote(
        in: scope, sources: [(source, sentence)], markdown: observation, requestID: UUID())
    let matches = try await model.readingNoteEvidence(query: "缓存预算", excluding: main.id)
    let hit = try #require(matches.first)
    #expect(matches.count == 1 && hit.readingNoteID == target.id && hit.text == observation)
    #expect(try await model.readingNoteEvidence(query: "computation").isEmpty)
    let citation = try await model.makeLocalPassageCitation(evidence: hit, quote: hit.text)
    #expect(citation.readingNoteID == target.id && citation.anchors.isEmpty)
    await #expect(throws: ReaderError.self) { try await model.makeLocalPassageCitation(evidence: hit, quote: sentence) }
    let block = try #require(main.blocks.first)
    let key = try #require(main.htmlReading?.sections.first?.id)
    let anchor = NoteAnchor(
        key: key.uuidString, target: "source", text: block.text, start: 0, end: block.text.utf16.count)
    let originID = UUID()
    let body = "跨论文比较。" + citation.markdown(label: "先前的判断")
    try model.insertLocalPassageCitation(citation, noteID: originID, anchors: [anchor], markdown: body)
    await model.flushReadingNotes()
    let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await restored.load()
    restored.select(main.id)
    #expect(try await restored.readingNoteEvidence(query: "缓存预算").map(\.readingNoteID) == [target.id])
    let preview = try await restored.previewLocalPassage(noteID: originID, citationID: citation.id)
    #expect(preview.noteMarkdown == observation && preview.readingNoteID == target.id)
    try await restored.openLocalPassage(preview)
    #expect(restored.selectedPaperID == pdf.id && restored.requestedReadingNote == target.id)
    let correction = "改正：真正限制在于显存容量。"
    #expect(restored.updateReadingNote(id: target.id, anchors: target.anchors, markdown: correction))
    await restored.flushReadingNotes()
    #expect(try await restored.readingNoteEvidence(query: "缓存预算").isEmpty)
    #expect(try await restored.readingNoteEvidence(query: "显存容量").first?.text == correction)
    await #expect(throws: ReaderError.self) {
        try await restored.makeLocalPassageCitation(evidence: hit, quote: hit.text)
    }
    #expect(throws: ReaderError.self) { try restored.validateLocalPassageTargets([citation]) }
    restored.select(main.id)
    let revised = try await restored.previewLocalPassage(noteID: originID, citationID: citation.id)
    #expect(revised.noteMarkdown == correction && !revised.quote.contains(observation))
    try await restored.openLocalPassage(revised)
    restored.deleteReadingNote(target.id)
    await restored.flushReadingNotes()
    restored.select(main.id)
    #expect(try await restored.readingNoteEvidence(query: "显存容量").isEmpty)
    await #expect(throws: ReaderError.self) { try await restored.openLocalPassage(revised) }
    await #expect(throws: ReaderError.self) {
        try await restored.previewLocalPassage(noteID: originID, citationID: citation.id)
    }
}

@Test @MainActor func localPassageLinksKeepTheChosenOccurrenceWhenAPDFRepeatsAnIdenticalSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, _, pdf) = try await makeCitationLibrary(root)
    let file = root.appendingPathComponent(pdf.originalPath)
    let quote = "We observed the same numerical result."
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    let font = CTFontCreateWithName("Georgia" as CFString, 12, nil)
    context.beginPDFPage(nil)
    for (index, text) in [quote, "We then performed a second trial.", quote].enumerated() {
        context.textPosition = CGPoint(x: 60, y: 550 - index * 40)
        CTLineDraw(
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
    }
    context.endPDFPage()
    context.closePDF()
    let raw = try #require(PDFDocument(url: file)?.page(at: 0)?.string) as NSString
    let locator = PDFReadingNoteLocator()
    let firstParts = try await locator.locate(
        quote: quote, pageIndex: 0, in: file, selectedRanges: [raw.range(of: quote)])
    let lastParts = try await locator.locate(
        quote: quote, pageIndex: 0, in: file, selectedRanges: [raw.range(of: quote, options: .backwards)])
    let first = LocalPassageCitation(
        paperID: pdf.id, digest: pdf.digest, contentVersion: pdf.digest + ":original-0",
        anchors: firstParts.map(\.anchor), quote: quote)
    let second = LocalPassageCitation(
        paperID: pdf.id, digest: pdf.digest, contentVersion: first.contentVersion, anchors: lastParts.map(\.anchor),
        quote: quote)
    #expect(first.id != second.id && first.anchors != second.anchors && first.quote == second.quote)
    let ambiguous = Evidence(id: "P1", title: pdf.title, text: quote, paperID: pdf.id, sourcePage: 0)
    await #expect(throws: ReaderError.self) {
        try await model.makeLocalPassageCitation(evidence: ambiguous, quote: quote)
    }
    let afterFirst = try await PDFReadingNoteLocator().citationContext(for: first, documentURL: file)
    let beforeSecond = try await PDFReadingNoteLocator().citationContext(for: second, documentURL: file)
    #expect(afterFirst.after.contains("second trial") && beforeSecond.before.contains("second trial"))
    try FileManager.default.removeItem(at: file)
    try AttentionFixture.write(to: file)
    await #expect(throws: ReaderError.self) {
        try await PDFReadingNoteLocator().citationContext(for: second, documentURL: file)
    }
}
