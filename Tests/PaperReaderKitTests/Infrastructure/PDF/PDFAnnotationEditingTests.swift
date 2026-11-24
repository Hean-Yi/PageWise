import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@Test func editingPartialPDFInkPreservesOriginalGeometryAndIndependentMarks() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try AttentionFixture.write(to: url)
    let original = try Data(contentsOf: url)
    let locator = PDFReadingNoteLocator()
    let paper = UUID()
    let full = try await locator.locate(quote: "Imagine a notebook", pageIndex: 0, in: url)
    let middle = try await locator.locate(quote: "a notebook", pageIndex: 0, in: url)
    let length = try #require(middle.first).anchor.start
    let cut = NSRange(location: length, length: 1)
    let piece = try await locator.selected(ranges: [cut], pageIndex: 0, in: url)
    var old = try #require(full.first).highlight(for: paper)
    old.pdfTextStart = nil
    var unknown = old
    unknown.id = UUID()
    unknown.text = "text the PDF does not contain"
    var differentPaper = old
    differentPaper.id = UUID()
    differentPaper.paperID = UUID()
    var translation = old
    translation.id = UUID()
    translation.pdfTranslationTarget = "translation-fixture"
    translation.textRange = [0, translation.text.utf16.count]
    let independent = [unknown, differentPaper, translation]
    #expect(try await locator.locatedHighlight(old, in: url).map(\.anchor) == full.map(\.anchor))
    await #expect(throws: ReaderError.self) { try await locator.locatedHighlight(unknown, in: url) }
    let before = independent + [old]
    let originalMenu = try await locator.appearance(for: piece, in: before, paperID: paper, documentURL: url)
    #expect(originalMenu == PDFAnnotationAppearance(covered: true, color: .yellow, style: .highlight))
    let upgraded = try await locator.applying(
        piece, to: before, paperID: paper, color: .yellow, style: .highlight, in: url)
    #expect(upgraded.last?.pdfTextStart == full.first?.anchor.start && upgraded.last?.id == old.id)
    #expect(Array(upgraded.dropLast()) == independent)
    let changed = try await locator.applying(
        piece, to: before, paperID: paper, color: .purple, style: .underline, in: url)
    #expect(Array(changed.prefix(independent.count)) == independent)
    let ink = changed.filter { $0.pdfTextStart != nil }.sorted { $0.pdfTextStart! < $1.pdfTextStart! }
    #expect(ink.map(\.text) == ["Imagine ", "a", " notebook"])
    #expect(ink.map(\.color) == [nil, .purple, nil])
    #expect(ink.map(\.style) == [nil, .underline, nil])
    #expect(ink.first?.id == old.id && ink.first?.createdAt == old.createdAt && ink.last?.createdAt == old.createdAt)
    #expect(Set(changed.map(\.id)).count == changed.count)
    for mark in ink {
        let range = NSRange(location: try #require(mark.pdfTextStart), length: mark.text.utf16.count)
        let actual = try await locator.selected(ranges: [range], pageIndex: 0, in: url)
        #expect(mark.rects == actual.first?.rects)
    }
    let menu = try await locator.appearance(for: full, in: changed, paperID: paper, documentURL: url)
    #expect(menu == PDFAnnotationAppearance(covered: true))
    let same = try await locator.applying(
        piece, to: changed, paperID: paper, color: .purple, style: .underline, in: url)
    #expect(same == changed)
    let erased = try await locator.applying(
        piece, to: changed, paperID: paper, color: .purple, style: .underline, removing: true, in: url)
    #expect(erased == changed.filter { $0.id != ink[1].id })
    #expect(
        try await locator.appearance(for: piece, in: erased, paperID: paper, documentURL: url)
            == PDFAnnotationAppearance())
    #expect(try Data(contentsOf: url) == original)
}
