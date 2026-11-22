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

@Test func pdfParagraphSpacingSeparatesReadingWithoutChangingCacheAnchors() throws {
    let url = try sentenceFixture([
        (50, 680, "Our first sample spans"), (50, 668, "two lines. Another sentence follows."),
        (50, 651, "The next sample starts on its own."), (50, 639, "A second observation follows."),
        (50, 627, "The final value is stable."),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let pairs = try PDFSentenceExtractor.extract(url: url, pageIndex: 0)
    try #require(pairs.count == 5)
    #expect(pairs[0].rects.count == 2)
    #expect(Set(pairs.map(\.paragraphID)).count == 1)
    #expect(pairs[0].readingParagraphID == pairs[1].readingParagraphID)
    #expect(pairs[1].readingParagraphID != pairs[2].readingParagraphID)
    #expect(Set(pairs[2...].map(\.readingParagraphID)).count == 1)
    let offset = try #require(pairs[2].characterRanges.first?.location)
    #expect(pairs[2].id == "p0-s\(offset)")
    #expect(pairs[2].readingParagraphID == "p0-b\(offset)")
}

@Test func pdfParagraphSkipsSentenceCrossingFromTableCellIntoCaption() throws {
    let url = try sentenceFixture(
        [(185, 664, "Granite and mica]"), (90, 652, "Table 2. Timing summary."), (50, 608, "The trial ended.")],
        fontSizesByBaseline: [664: 8])
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    #expect(result.sentences.map(\.text) == ["Timing summary.", "The trial ended."])
    #expect(result.notice?.contains("表 2 附近") == true)
}

@Test func pdfParagraphJoinsVerifiedHangingHeadingAndFlagsAnIncompleteOne() throws {
    let url = try sentenceFixture(
        [
            (50, 670, "3. Measurements in"), (62, 656, "Repeated Trials"),
            (50, 632, "3.1. Sampling Procedure"), (50, 606, "We record the output."),
            (50, 558, "4. Changes in"), (62, 544, "Results remain consistent."),
        ], fontSizesByBaseline: [670: 12, 656: 12, 558: 12, 544: 12])
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    #expect(
        result.sentences.map(\.text) == [
            "3. Measurements in Repeated Trials", "3.1. Sampling Procedure", "We record the output.",
            "Results remain consistent.",
        ])
    #expect(result.notice?.contains("第 4 节标题处") == true)
    let heading = try #require(result.sentences.first)
    #expect(heading.rects.count == 2)
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    #expect(
        heading.characterRanges.compactMap { page.selection(for: $0)?.string } == [
            "3. Measurements in", "Repeated Trials",
        ])
}

private func sentenceFixture(
    _ lines: [(CGFloat, CGFloat, String)], supporting: [(CGFloat, CGFloat, String)]? = nil,
    fontSizesByBaseline: [CGFloat: CGFloat] = [:]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for pageLines in [lines, supporting].compactMap({ $0 }) {
        context.beginPDFPage(nil)
        context.stroke(CGRect(x: 45, y: 85, width: 110, height: 50))
        for (x, y, line) in pageLines {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSizesByBaseline[y] ?? 10, nil)
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
