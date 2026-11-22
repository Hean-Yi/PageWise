import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func pdfSentenceExtractorMapsInterleavedColumnsToSourceLines() throws {
    let url = try sentenceFixture([
        (40, 650, "The first column describes a new transla-"),
        (315, 650, "The other column starts with Fig. 2."),
        (40, 634, "tion method. It retains 3.25 ms."),
        (315, 634, "The second observation concerns latency."),
        (40, 618, "The cache stays warm. The cache stays warm."),
        (315, 618, "The last thought continues on"),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try Data(contentsOf: url)
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    let expected = [
        "The first column describes a new translation method.", "It retains 3.25 ms.",
        "The cache stays warm.", "The cache stays warm.", "The other column starts with Fig. 2.",
        "The second observation concerns latency.",
    ]
    #expect(result.sentences.map(\.text) == expected)
    #expect(result.notice != nil)
    let pairs = result.sentences
    try #require(pairs.count == expected.count)
    #expect(pairs[0].rects.count == 2)
    #expect(pairs[2].id != pairs[3].id)
    #expect(pairs[2].characterRanges != pairs[3].characterRanges)
    #expect(pairs[0].paragraphID != pairs[4].paragraphID)
    #expect(pairs[0].rects.allSatisfy { $0[0] < 310 && $0[0] + $0[2] < 310 })
    #expect(pairs[4].rects.allSatisfy { $0[0] >= 310 })

    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    for index in [2, 3, 4] {
        let sentence = pairs[index]
        let range = try #require(sentence.characterRanges.first)
        let selection = try #require(page.selection(for: range))
        #expect(selection.string == sentence.text)
        let b = selection.bounds(for: page)
        let rect = try #require(sentence.rects.first)
        let expected: [Double] = [b.minX, b.minY, b.width, b.height]
        #expect(rect.count == 4)
        #expect(zip(rect, expected).allSatisfy { abs($0 - $1) < 0.001 })
    }
    #expect(try PDFSentenceExtractor.extract(url: url, pageIndex: 0) == pairs)
    #expect(try Data(contentsOf: url) == data)
}

@Test func pdfSentenceExtractorDoesNotTranslateUnreadablePage() throws {
    let url = try sentenceFixture([])
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    #expect(result.sentences.isEmpty)
    #expect(result.notice?.contains("没有可提取") == true)
    #expect(throws: ReaderError.self) { try PDFSentenceExtractor.extract(url: url, pageIndex: 0) }
    #expect(throws: ReaderError.self) { try PDFSentenceExtractor.extractPage(url: url, pageIndex: 2) }
}

@Test func pdfSentenceExtractorKeepsHeadingWholeAndStopsAtReferences() throws {
    let url = try sentenceFixture([
        (54, 675, "1. Introduction"), (54, 650, "The sensor recorded the outcome."),
        (54, 588, "References"), (54, 563, "A. Author. A separate publication."),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    #expect(result.sentences.map(\.text) == ["1. Introduction", "The sensor recorded the outcome."])
    #expect(result.notice != nil)
}

@Test func pdfSentenceExtractorKeepsTitleAndAbstractSeparateFromByline() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try DemoPaper.write(to: url)
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    #expect(result.sentences.prefix(2).map(\.text) == ["Understanding Attention", "Abstract"])
    #expect(result.sentences.contains { $0.text.contains("score") })
    #expect(!result.sentences.contains { $0.text.contains("An original teaching note") })
    #expect(result.notice != nil)
}

@Test func pdfSentenceExtractorUsesNearbySpellingsAndKeepsSourceOffsets() throws {
    let url = try sentenceFixture(
        [
            (40, 665, "We track con-"), (40, 650, "versational memory."),
            (40, 610, "An optical wave-"), (40, 595, "front is visible."),
            (40, 555, "We track nara-"), (40, 540, "zithic drift."),
        ],
        supporting: [
            (40, 665, "We measured conversational features."),
            (40, 630, "We compare the wave-front and wavefront variants."),
        ])
    defer { try? FileManager.default.removeItem(at: url) }
    let sentences = try PDFSentenceExtractor.extract(url: url, pageIndex: 0)
    #expect(
        sentences.map(\.text) == [
            "We track conversational memory.", "An optical wave-front is visible.", "We track nara-zithic drift.",
        ])
    let first = try #require(sentences.first)
    #expect(first.rects.count == 2)
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    #expect(
        first.characterRanges.compactMap { page.selection(for: $0)?.string } == [
            "We track con-", "versational memory.",
        ])
}

private func sentenceFixture(
    _ lines: [(CGFloat, CGFloat, String)], supporting: [(CGFloat, CGFloat, String)]? = nil
) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    for pageLines in [lines, supporting].compactMap({ $0 }) {
        context.beginPDFPage(nil)
        context.stroke(CGRect(x: 45, y: 85, width: 110, height: 50))
        for (x, y, line) in pageLines {
            let text = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return url
}
