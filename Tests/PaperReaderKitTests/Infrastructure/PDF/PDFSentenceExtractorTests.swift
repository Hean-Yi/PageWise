import CoreGraphics
import CoreText
import Foundation
import ImageIO
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

@Test func pdfSentenceExtractorSeparatesWrappedTableAndCaptionFromSurroundingProse() throws {
    let url = try sentenceFixture(
        [
            (67, 665, "The coastal survey spans several remote islands surrounding the neighboring mainland."),
            (67, 620, "The rocky coast had many seabirds"),
            (67, 608, "above the rocks. Our team found"),
            (67, 596, "two new nests beside the old cliffs"),
            (67, 584, "where the boats dropped their load."),
            (67, 566, "The team surveys the western region"),
            (67, 554, "before counting the seals along the"),
            (67, 542, "shore. The samples are processed with care in the laboratory under controlled conditions."),
            (242, 634, "Site"), (389, 634, "Count"),
            (242, 619, "Bay"), (389, 619, "31"),
            (242, 608, "Pier"), (389, 608, "29"),
            (241, 589, "Table 2: A summary of counts."),
            (241, 577, "The paired trials show that higher"),
            (241, 565, "counts indicate a stronger current."),
        ], rules: [646, 630, 603].map { CGRect(x: 240, y: $0, width: 234, height: 1) })
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, includingIllustrations: true)
    let queue = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, illustrations: .translation)
    #expect(result.paragraphSentences == queue.paragraphSentences)
    let paragraphs = result.paragraphSentences
    let body = try #require(paragraphs.first { $0.text.hasPrefix("The team surveys") })
    #expect(body.text == "The team surveys the western region before counting the seals along the shore.")
    #expect(body.rects.count == 3 && body.rects.allSatisfy { $0[0] + $0[2] < 241 })
    let caption = try #require(paragraphs.first { $0.text.hasPrefix("Table 2:") })
    let continuation = try #require(paragraphs.first { $0.text.hasPrefix("The paired trials") })
    #expect(continuation.text == "The paired trials show that higher counts indicate a stronger current.")
    #expect(continuation.rects.count == 2 && continuation.rects.allSatisfy { $0[0] >= 240 })
    let table = try #require(result.illustrations.first { $0.label == "表 2" })
    #expect(table.imagePNG != nil && table.insertBeforeSentenceID == caption.id)
    #expect(!paragraphs.contains { $0.text.contains("31") || $0.text.contains("29") })
    let expected = ["The team surveys the western region", "before counting the seals along the", "shore."]
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    #expect(body.characterRanges.compactMap { page.selection(for: $0)?.string } == expected)
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

@Test(arguments: ["References", "Bibliography"])
func pdfSentenceExtractorExplainsReferencesPageAndReadsFollowingAppendix(_ heading: String) throws {
    let url = try sentenceFixture(
        [(54, 650, heading), (54, 624, "[1] A. Reader. A separate publication.")],
        supporting: [(54, 650, "The appendix describes the measurement.")])
    defer { try? FileManager.default.removeItem(at: url) }
    let references = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, includingIllustrations: true)
    #expect(references.paragraphSentences.isEmpty)
    #expect(references.notice == "本页为参考文献，保留原文。")
    #expect(references.paragraphNotice == nil)
    let page = try #require(references.illustrations.first { $0.presentation == .originalPage })
    #expect(page.pageIndex == 0 && page.insertBeforeSentenceID == nil)
    try checkReadableImage(page)
    let queued = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, illustrations: .translation)
    #expect(queued.illustrations.isEmpty && queued.paragraphSentences.isEmpty)
    let appendix = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 1, includingIllustrations: true)
    #expect(appendix.paragraphSentences.map(\.text) == ["The appendix describes the measurement."])
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

@Test func pdfRemainderOmitsPageFurnitureAndKeepsTheUnpairedPartOfALine() throws {
    let clear = try sentenceFixture([(54, 650, "A complete sentence is readable."), (300, 32, "1")])
    let partial = try sentenceFixture([(54, 650, "The trial ended. This continues"), (300, 32, "1")])
    defer {
        try? FileManager.default.removeItem(at: clear)
        try? FileManager.default.removeItem(at: partial)
    }
    let fullPage = try PDFSentenceExtractor.extractPage(url: clear, pageIndex: 0)
    #expect(fullPage.notice == nil && fullPage.unpairedBounds.isEmpty)
    let result = try PDFSentenceExtractor.extractPage(url: partial, pageIndex: 0)
    #expect(result.sentences.map(\.text) == ["The trial ended."])
    #expect(!result.hasUnlocatedText)
    let document = try #require(PDFDocument(url: partial))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    let excerpt = try #require(result.unpairedBounds.first)
    let original = try #require(page.selection(for: excerpt)?.string)
    #expect(original.contains("This continues"))
    #expect(!original.contains("trial"))
    #expect(result.unpairedBounds.allSatisfy { $0.minY > 600 })
}

@Test func pdfReadingRestoresMixedProseInPlaceWithMatchingTranslationQueueAnchors() throws {
    let url = try sentenceFixture([
        (54, 675, "The trial ended."), (54, 635, "An unpaired line"), (54, 585, "The next experiment begins."),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let reading = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, includingIllustrations: true)
    let excerpt = try #require(reading.illustrations.first { $0.presentation == .excerpt })
    try checkReadableImage(excerpt)
    let next = try #require(reading.sentences.first { $0.text == "The next experiment begins." })
    #expect(excerpt.insertBeforeSentenceID == next.id)
    #expect(reading.paragraphNotice == nil)
    let plain = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0)
    let queued = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, illustrations: .translation)
    #expect(queued.illustrations.isEmpty)
    #expect(queued.paragraphSentences == reading.paragraphSentences)
    #expect(queued.sentences == plain.sentences)
}

@Test func pdfReadingKeepsUnlocatedTableAtItsCaptionWithOneInlineSupplement() throws {
    let url = try sentenceFixture([
        (54, 685, "The reader first sees this paragraph."),
        (54, 570, "Table 9: Unlocated boundaries."),
        (54, 542, "The explanation continues below the table."),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)
    let reading = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, includingIllustrations: true)
    let supplements = reading.illustrations.filter { $0.presentation == .supplement }
    try #require(supplements.count == 1)
    let supplement = supplements[0]
    let caption = try #require(reading.sentences.first { $0.text.hasPrefix("Table 9") })
    #expect(supplement.label.contains("表 9") && supplement.insertBeforeSentenceID == caption.id)
    #expect(supplement.table == nil)
    #expect(reading.illustrations.allSatisfy { $0.imagePNG != nil })
    #expect(reading.paragraphNotice == nil)
    try checkReadableImage(supplement)
    let queued = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, illustrations: .translation)
    #expect(queued.illustrations.allSatisfy { $0.imagePNG == nil })
    #expect(queued.paragraphSentences == reading.paragraphSentences)
    #expect(try Data(contentsOf: url) == original)
}

@Test func pdfReadingDisplaysRasterOnlyPageInlineWithoutSendingText() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    let raster = try #require(
        CGContext(
            data: nil, width: 80, height: 100, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    raster.setFillColor(gray: 1, alpha: 1)
    raster.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
    raster.setFillColor(gray: 0, alpha: 1)
    raster.fill(CGRect(x: 10, y: 20, width: 45, height: 30))
    let image = try #require(raster.makeImage())
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var sourceBounds = CGRect(x: 0, y: 0, width: 320, height: 400)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &sourceBounds, nil))
    context.beginPDFPage(nil)
    context.draw(image, in: sourceBounds)
    context.endPDFPage()
    context.closePDF()
    let reading = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, includingIllustrations: true)
    #expect(reading.sentences.isEmpty && reading.paragraphNotice == nil)
    try #require(reading.illustrations.count == 1)
    let preview = reading.illustrations[0]
    #expect(preview.presentation == .originalPage && preview.sourceBounds == sourceBounds)
    try checkReadableImage(preview)
    let queued = try PDFSentenceExtractor.extractPage(url: url, pageIndex: 0, illustrations: .translation)
    #expect(queued.illustrations.isEmpty && queued.paragraphSentences.isEmpty)
}

private func checkReadableImage(_ illustration: PDFReadingIllustration) throws {
    let data = try #require(illustration.imagePNG)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width > 0 && image.height > 0 && image.width * image.height <= 2_097_152)
}

@Test func pdfRemainderKeepsUncoveredRowsAndAvoidsRepeatedTableAndParagraphText() throws {
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    let table = CGRect(x: 40, y: 640, width: 300, height: 70)
    let uncovered = CGRect(x: 350, y: 660, width: 40, height: 12)
    let pair = PDFSourceSentence(
        id: "visible", text: "Verified text.", pageIndex: 0, rects: [[40, 604, 120, 11]], paragraphID: "p")
    let regions = PDFSourceRemainder.regions(
        for: [
            CGRect(x: 45, y: 645, width: 35, height: 10), uncovered,
            CGRect(x: 43, y: 619, width: 60, height: 10), CGRect(x: 42, y: 590, width: 55, height: 10),
        ],
        excluding: [table], sentences: [pair], cropBox: page)
    #expect(regions.count == 3)
    #expect(regions.contains { $0.contains(uncovered) })
    #expect(!regions.contains { $0.intersects(table) })
    #expect(!regions.contains { $0.intersects(CGRect(x: 40, y: 604, width: 120, height: 11)) })
}

@Test func pdfRemainderPreservesAnEquationsRightMarginNumberInItsOriginalPosition() {
    let paper = CGRect(x: 0, y: 0, width: 600, height: 800)
    let formula = CGRect(x: 205, y: 620, width: 165, height: 15)
    let number = CGRect(x: 480, y: 621, width: 14, height: 11)
    let prose = PDFSourceSentence(
        id: "long", text: "A paragraph.", pageIndex: 0,
        rects: [[85, 680, 421, 11], [85, 665, 420, 11], [85, 650, 422, 11]], paragraphID: "p")
    let oneColumn = PDFSourceRemainder.regions(
        for: [formula, number], excluding: [], sentences: [prose], cropBox: paper)
    #expect(oneColumn.count == 1 && oneColumn[0].contains(formula.union(number)))
    let columns = PDFSourceSentence(
        id: "columns", text: "Parallel columns.", pageIndex: 0,
        rects: [[80, 598, 190, 11], [310, 598, 190, 11]], paragraphID: "p")
    let twoColumns = PDFSourceRemainder.regions(
        for: [formula, number], excluding: [], sentences: [prose, columns], cropBox: paper)
    #expect(twoColumns.count == 2)
}

private func sentenceFixture(
    _ lines: [(CGFloat, CGFloat, String)], supporting: [(CGFloat, CGFloat, String)]? = nil,
    fontSizesByBaseline: [CGFloat: CGFloat] = [:], rules: [CGRect] = []
) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for pageLines in [lines, supporting].compactMap({ $0 }) {
        context.beginPDFPage(nil)
        context.stroke(CGRect(x: 45, y: 85, width: 110, height: 50))
        for rule in rules { context.fill(rule) }
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
