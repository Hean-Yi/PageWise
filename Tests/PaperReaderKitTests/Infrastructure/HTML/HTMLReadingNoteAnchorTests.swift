import Foundation
import Testing

@testable import PaperReaderKit

private struct QuoteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let paperID = UUID()
    let first = UUID()
    let second = UUID()
    let artifact: HTMLReadingArtifact
    let store = HTMLReadingStore()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = "reading.html"
        let sections = [first, second].map { PageArtifact(id: $0, blockIDs: [$0], sourcePage: -1, relativePath: path) }
        artifact = .init(relativePath: path, sections: sections, assets: [])
        let html = """
            <!doctype html><html><body data-paper-id="\(paperID.uuidString)"><main id="reader">\
            <section id="block-\(first)" data-key="\(first)"><p>🧪<math><mi>hidden</mi></math> Data&nbsp; <em>&amp; nets</em></p>\
            <p class="pending">draft</p><p>Mark here. Mark here.</p><span class="translation">可重复。可重复。</span></section>\
            <section id="block-\(second)" data-key="\(second)"><p>Data &amp; nets</p><p class="translation">另一组实验。</p></section>\
            </main></body></html>
            """
        try Data(html.utf8).write(to: root.appendingPathComponent(path))
    }

    func resolve(_ quote: String, _ evidence: Evidence, selection: [NoteAnchor] = []) async throws -> [NoteAnchor] {
        try await store.noteAnchors(
            for: quote, evidence: evidence, paperID: paperID, artifact: artifact, root: root, selection: selection)
    }
}

@Test func readingNoteQuoteUsesOnlyVerifiedSectionDOMOffsetsAndActualUnicode() async throws {
    let fixture = try QuoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = fixture.root.appendingPathComponent(fixture.artifact.relativePath)
    let before = try Data(contentsOf: file)
    var evidence = Evidence(
        id: "S1", title: "Test", text: "Data & nets", paperID: fixture.paperID, blockID: fixture.first)
    let result = try await fixture.resolve("Data & nets", evidence)
    #expect(
        result == [
            .init(key: fixture.first.uuidString, target: "source", text: "Data\u{00a0} & nets", start: 3, end: 15)
        ])
    evidence.text = "hidden Data"
    await #expect(throws: ReaderError.self) { try await fixture.resolve("hidden Data", evidence) }
    evidence.text = "🧪 Data"
    await #expect(throws: ReaderError.self) { try await fixture.resolve("🧪 Data", evidence) }
    evidence.text = "draft"
    await #expect(throws: ReaderError.self) { try await fixture.resolve("draft", evidence) }
    evidence.text = "Data & nets"
    evidence.blockID = UUID()
    await #expect(throws: ReaderError.self) { try await fixture.resolve("Data & nets", evidence) }
    evidence.blockID = fixture.first
    evidence.paperID = UUID()
    await #expect(throws: ReaderError.self) { try await fixture.resolve("Data & nets", evidence) }
    #expect(try Data(contentsOf: file) == before)
}

@Test func readingNoteQuoteRepeatedInSameBlockRequiresVerifiedSelection() async throws {
    let fixture = try QuoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let evidence = Evidence(
        id: "S1", title: "Test", text: "Mark here.", paperID: fixture.paperID, blockID: fixture.first)
    await #expect(throws: ReaderError.self) { try await fixture.resolve("Mark here.", evidence) }
    let selected = NoteAnchor(key: fixture.first.uuidString, target: "source", text: "Mark here.", start: 26, end: 36)
    #expect(try await fixture.resolve("Mark here.", evidence, selection: [selected]) == [selected])
    var stale = selected
    stale.start -= 1
    stale.end -= 1
    await #expect(throws: ReaderError.self) { try await fixture.resolve("Mark here.", evidence, selection: [stale]) }
}

@Test func readingNoteQuoteSpanningSelectedTranslationsPreservesTheTwoHandSelectedRanges() async throws {
    let fixture = try QuoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let evidence = Evidence(id: "S2", title: "Selection", text: "可重复。\n\n另一组实验。", paperID: fixture.paperID)
    let first = NoteAnchor(key: fixture.first.uuidString, target: "translation", text: "可重复。", start: 4, end: 8)
    let second = NoteAnchor(key: fixture.second.uuidString, target: "translation", text: "另一组实验。", start: 0, end: 6)
    let selection = [first, second]
    let partialQuote = "重复。 另一组"
    #expect(
        try await fixture.resolve(partialQuote, evidence, selection: selection) == [
            .init(key: first.key, target: "translation", text: "重复。", start: 5, end: 8),
            .init(key: second.key, target: "translation", text: "另一组", start: 0, end: 3),
        ])
    await #expect(throws: ReaderError.self) { try await fixture.resolve(partialQuote, evidence) }
    var unrelated = evidence
    unrelated.text = "另一问题"
    await #expect(throws: ReaderError.self) { try await fixture.resolve(partialQuote, unrelated, selection: selection) }
}

@Test func readingNoteQuoteForHandSelectedFormulaKeepsTheSameWholeObjectAnchor() async throws {
    let fixture = try QuoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let math = NoteAnchor(key: fixture.first.uuidString, target: "object:0", text: "[公式] hidden", start: 0, end: 11)
    let evidence = Evidence(
        id: "S1", title: "Formula", text: math.text, paperID: fixture.paperID, blockID: fixture.first)
    #expect(try await fixture.resolve(math.text, evidence, selection: [math]) == [math])
    await #expect(throws: ReaderError.self) { try await fixture.resolve("hidden", evidence, selection: [math]) }
    var invalid = math
    invalid.target = "object:1"
    await #expect(throws: ReaderError.self) { try await fixture.resolve(math.text, evidence, selection: [invalid]) }
}

@Test func quoteReadsOnlyItsIndexedSectionAndReusesVerifiedStreamsForContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paper = Paper(
        title: "Scoped HTML", digest: "local", originalPath: "test.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    let first = TextBlock(sourcePage: 0, text: "Other section")
    let second = TextBlock(sourcePage: 0, text: "🧪 Before quoted words after.")
    let store = HTMLReadingStore()
    let artifact = try await store.append(
        [first, second].map { .init(block: $0, translation: nil) },
        to: nil, paper: paper, root: root)
    let url = root.appendingPathComponent(artifact.relativePath)
    let index = try #require(artifact.sectionIndex)
    // Deliberately invalid UTF-8 in an unrelated section detects a fallback to whole-file decoding.
    let file = try FileHandle(forWritingTo: url)
    try file.seek(toOffset: index.start)
    try file.write(contentsOf: Data([0xFF]))
    try file.close()
    let quote = "quoted words"
    let evidence = Evidence(id: "S1", title: "Test", text: second.text, paperID: paper.id, blockID: second.id)
    let anchors = try await store.noteAnchors(
        for: quote, evidence: evidence, paperID: paper.id,
        artifact: artifact, root: root)
    #expect(anchors == [.init(key: second.id.uuidString, target: "source", text: quote, start: 10, end: 22)])
    let reference = LocalPassageCitation(
        paperID: paper.id, digest: paper.digest, contentVersion: "test",
        anchors: anchors, quote: quote)
    let context = try await store.citationContext(for: reference, artifact: artifact, root: root)
    #expect(context.before == "🧪 Before ")
    #expect(context.after == " after.")
    try FileManager.default.removeItem(at: url)
    await #expect(throws: (any Error).self) {
        try await store.citationContext(for: reference, artifact: artifact, root: root)
    }
}

@Test func oldQuoteCacheCannotResurrectADeletedPublishedEdition() async throws {
    let fixture = try QuoteFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let quote = "Data & nets"
    let evidence = Evidence(id: "S1", title: "Test", text: quote, paperID: fixture.paperID, blockID: fixture.second)
    #expect(try await !fixture.resolve(quote, evidence).isEmpty)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(fixture.artifact.relativePath))
    await #expect(throws: (any Error).self) { try await fixture.resolve(quote, evidence) }
}
