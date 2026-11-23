import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func pageLocatorFollowsStableArtifactIDAfterPageArrayChanges() throws {
    var paper = navigationPaper()
    let saved = ReaderPosition(mode: "reflow", pageKey: paper.previewPages[1].id.uuidString, pageIndex: 1)
    paper.previewPages.insert(PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "earlier.pdf"), at: 0)
    let restored = try #require(PaperPageLocator.resolve(pageKey: saved.pageKey, in: paper))
    #expect(restored.mode == "reflow")
    #expect(restored.pageIndex == 2)
    #expect(PaperPageLocator.sourcePage(for: restored, in: paper) == 2)
    let translated = try #require(PaperPageLocator.position(sourcePage: 2, mode: "translated", in: paper))
    #expect(translated.pageKey == paper.translatedPages[0].id.uuidString)
    #expect(translated.pageIndex == 0)
    #expect(PaperPageLocator.resolve(pageKey: "missing-layout-page", in: paper) == nil)
    #expect(PaperPageLocator.resolve(pageKey: "original-5", in: paper) == nil)
}

@Test func pendingArtifactsAndUntranslatedSourcesHaveNoPublishedTranslationLocation() throws {
    let paper = navigationPaper()
    #expect(PaperPageLocator.position(sourcePage: 0, mode: "translated", in: paper) == nil)
    #expect(
        PaperPageLocator.position(
            sourcePage: 2, mode: "translated", in: paper, excluding: [paper.translatedPages[0].id]) == nil)
    #expect(
        PaperPageLocator.resolve(
            pageKey: paper.translatedPages[0].id.uuidString, in: paper, excluding: [paper.translatedPages[0].id]) == nil
    )
    #expect(PaperPageLocator.position(sourcePage: 2, mode: "original", in: paper)?.pageKey == "original-2")
}

@Test func unpublishedBlockCannotJumpToAnotherBlockOnTheSameSourcePage() {
    var paper = navigationPaper()
    let unpublished = TextBlock(sourcePage: 2, text: "Not translated yet.")
    paper.blocks.append(unpublished)
    #expect(PaperPageLocator.position(sourcePage: 2, blockID: unpublished.id, mode: "translated", in: paper) == nil)
}

@Test func paperSearchExcerptIncludesMatchNearTheEndOfALongParagraph() throws {
    var paper = navigationPaper()
    paper.blocks[0].text = String(repeating: "Earlier context. ", count: 100) + "MATCH_NEAR_END"
    let result = try #require(PaperTextSearch.search("MATCH_NEAR_END", in: paper).first)
    #expect(result.text.contains("MATCH_NEAR_END"))
    #expect(result.text.count <= 222)
}

@Test func paperSearchFindsOnlyLocalCompletedTextWithItsSourceAnchor() throws {
    var paper = navigationPaper()
    paper.translations[paper.blocks[0].id.uuidString] = "尚未发布的秘密译文"
    let matches = PaperTextSearch.search("注意力", in: paper)
    let hit = try #require(matches.first)
    #expect(matches.count == 1)
    #expect(hit.isTranslation)
    #expect(hit.paperID == paper.id)
    #expect(hit.blockID == paper.blocks[1].id)
    #expect(hit.sourcePage == 2)
    #expect(PaperTextSearch.search("ATTENTION", in: paper).first?.isTranslation == false)
    #expect(PaperTextSearch.search("ATTENTION", in: paper).first?.matchedText == "Attention")
    #expect(PaperTextSearch.search("秘密", in: paper).isEmpty)
    #expect(PaperTextSearch.search("注意力", in: paper, excluding: [paper.translatedPages[0].id]).isEmpty)
    #expect(PaperTextSearch.search(" \n ", in: paper).isEmpty)
}

@Test func fixedPageTextMatchingHandlesPDFLineBreaksWithoutInventingAMatch() {
    #expect(PaperTextSearch.containsLocationContext("精确定位", in: "已有文字\n精确\n定位译文"))
    #expect(PaperTextSearch.containsLocationContext("query key", in: "QUERY\nkey"))
    #expect(!PaperTextSearch.containsLocationContext("attention", in: "unrelated text"))
    #expect(!PaperTextSearch.containsLocationContext(" \n", in: "unrelated text"))
}

@Test func translatedSearchContextKeepsRealSurroundingTextWithoutDisplayEllipses() throws {
    var paper = navigationPaper()
    let prefix = String(repeating: "前", count: 70)
    let suffix = String(repeating: "后", count: 70)
    paper.translations[paper.blocks[1].id.uuidString] = prefix + "Transformer" + suffix
    let result = try #require(PaperTextSearch.search("Transformer", in: paper).first { $0.isTranslation })
    #expect(
        result.matchingContext == String(repeating: "前", count: 40) + "Transformer" + String(repeating: "后", count: 40))
    #expect(!result.hasAmbiguousTranslationContext)
    paper.translations[paper.blocks[1].id.uuidString] = paper.blocks[1].text
    let ambiguous = try #require(PaperTextSearch.search("Attention", in: paper).first { $0.isTranslation })
    #expect(ambiguous.hasAmbiguousTranslationContext)
}

@Test func fixedPageTextLocatorReportsMissingArtifacts() async throws {
    let page = PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "missing.pdf")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: (any Error).self) {
        try await PDFPageTextLocator().pageKey(matching: "match", in: [page], root: root)
    }
}

@Test func paperSearchCapsResultsAndPageFallbackDoesNotInventHeadings() {
    var paper = navigationPaper()
    paper.blocks = (0..<100).map { TextBlock(sourcePage: $0 % 3, text: "Repeated matching text \($0)") }
    #expect(PaperTextSearch.search("matching", in: paper).count == PaperTextSearch.maximumResults)
    let items = PaperNavigationItem.pages(for: paper)
    #expect(items.map(\.sourcePage) == [0, 1, 2])
    #expect(items.allSatisfy { !$0.isOutline && $0.depth == 0 })
    #expect(items[0].title.contains("Repeated matching text 0"))
}

@Test func pageFallbackSkipsRepeatedPaperTitleAndPrefersRealBodyExcerpt() {
    var paper = navigationPaper()
    paper.title = "Understanding Attention"
    let body =
        "This paragraph is long enough to describe the real content on the first source page without inventing a heading."
    paper.blocks = [
        TextBlock(sourcePage: 0, text: "  Understanding   Attention \n"),
        TextBlock(sourcePage: 0, text: "Abstract"),
        TextBlock(sourcePage: 0, text: body),
        TextBlock(sourcePage: 1, text: paper.title),
        TextBlock(sourcePage: 1, text: "Only a short real excerpt."),
        TextBlock(sourcePage: 2, text: paper.title),
    ]
    let items = PaperNavigationItem.pages(for: paper)
    #expect(items[0].title == "第 1 页 · " + String(body.prefix(80)))
    #expect(items[1].title == "第 2 页 · Only a short real excerpt.")
    #expect(items[2].title == "第 3 页")
    #expect(items.allSatisfy { !$0.isOutline })
}

@Test @MainActor func pdfOutlineServiceUsesRealTitlesAndNestedPageDestinations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("outline.pdf")
    try DemoPaper.write(to: file)
    let document = try #require(PDFDocument(url: file))
    let outline = PDFOutline()
    let first = PDFOutline()
    first.label = "Actual first title"
    first.destination = PDFDestination(page: try #require(document.page(at: 0)), at: .zero)
    let nested = PDFOutline()
    nested.label = "Actual nested title"
    nested.action = PDFActionGoTo(destination: PDFDestination(page: try #require(document.page(at: 1)), at: .zero))
    let third = PDFOutline()
    third.label = "Nested detail"
    third.destination = first.destination
    nested.insertChild(third, at: 0)
    first.insertChild(nested, at: 0)
    let titleWrapper = PDFOutline()
    titleWrapper.label = navigationPaper().title
    titleWrapper.destination = first.destination
    titleWrapper.insertChild(first, at: 0)
    outline.insertChild(titleWrapper, at: 0)
    document.outlineRoot = outline
    #expect(document.write(to: file))
    let bytes = try Data(contentsOf: file)
    var paper = navigationPaper()
    paper.originalPath = "outline.pdf"
    paper.pageCount = 2
    let items = try await PDFOutlineService().items(for: paper, root: root)
    #expect(items.map(\.title) == ["Actual first title", "Actual nested title"])
    #expect(items.map(\.sourcePage) == [0, 1])
    #expect(items.map(\.depth) == [0, 1])
    #expect(items.allSatisfy { $0.isOutline && $0.sourcePoint != nil })
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func printedOutlineUsesRealTwoLevelHeadingsAndDistinctAnchorsOnOnePage() throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 500, height: 700)
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let lines: [(String, CGFloat, CGFloat)] = [
        ("A Generic Document Title", 18, 680), ("1. Novel methods for", 14, 650), ("layered inference", 14, 634),
        ("This is a regular line of text describing the approach in further detail.", 10, 595),
        ("1.1. Evaluation", 11, 560), ("1.1.1. Third-level detail", 10, 530),
        ("1. Choose a method for each group.", 10, 510), ("5.2. Orphaned item", 11, 485),
        ("1.2. Accuracy in practice.", 11, 452), ("2. Results", 14, 405),
        ("I. Supplementary analyses", 14, 365), ("A. Measurements", 10, 325),
        ("II. Further results", 14, 285), ("A. Limit cases", 10, 245),
    ]
    for (text, size, y) in lines {
        let string = NSAttributedString(
            string: text,
            attributes: [
                .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)
            ])
        context.textPosition = CGPoint(x: 48, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(data: data as Data))
    let page = try #require(document.page(at: 0))
    let items = try PDFPrintedOutline.items(in: document, paperID: UUID(), pageCount: 1)
    #expect(
        items.map(\.title) == [
            "1. Novel methods for layered inference", "1.1. Evaluation", "1.2. Accuracy in practice.", "2. Results",
            "I. Supplementary analyses", "A. Measurements", "II. Further results", "A. Limit cases",
        ])
    #expect(items.map(\.depth) == [0, 1, 1, 0, 0, 1, 0, 1])
    for item in items {
        let range = try #require(item.sourceRange)
        let text = try #require(page.selection(for: range)?.string)
        #expect(text.split(whereSeparator: \.isWhitespace).joined(separator: " ") == item.title)
    }
    #expect(try #require(items[1].sourcePoint).y > #require(items[2].sourcePoint).y)
}

private func navigationPaper() -> Paper {
    let blocks = [
        TextBlock(sourcePage: 0, text: "First local source."),
        TextBlock(sourcePage: 2, text: "Attention maps the local query to its source."),
    ]
    var paper = Paper(
        title: "Local fixture", digest: "local", originalPath: "original.pdf", pageCount: 3, blocks: blocks,
        warnings: [], canReflow: true)
    paper.previewPages = blocks.map {
        PageArtifact(blockIDs: [$0.id], sourcePage: $0.sourcePage, relativePath: "preview-\($0.sourcePage).pdf")
    }
    paper.translatedPages = [PageArtifact(blockIDs: [blocks[1].id], sourcePage: 2, relativePath: "translated-2.pdf")]
    paper.translations[blocks[1].id.uuidString] = "注意力将本地问题映射到原文。"
    paper.translatedBlockCount = 2
    return paper
}
