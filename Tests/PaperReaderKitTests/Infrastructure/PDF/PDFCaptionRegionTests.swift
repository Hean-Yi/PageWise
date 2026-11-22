import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func pdfCaptionRegionReadsFigureAndTableAtTheirSourceAnchors() throws {
    let url = try illustratedFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    for (i, label, required, captionText) in [
        (0, "图 1", CGRect(x: 73, y: 514, width: 275, height: 119), "Figure 1"),
        (1, "表 2", CGRect(x: 72, y: 508, width: 278, height: 81), "Table 2"),
    ] {
        let page = try #require(document.page(at: i))
        let region = try #require(try PDFCaptionRegionDetector.regions(on: page).first)
        #expect(region.label == label)
        #expect(page.selection(for: region.captionRange)?.string?.hasPrefix(captionText) == true)
        let rect = try #require(region.sourceBounds)
        #expect(rect.contains(required))
        #expect(!rect.intersects(region.captionBounds))
        let plain = try PDFSentenceExtractor.extractPage(url: url, pageIndex: i)
        let reading = try PDFSentenceExtractor.extractPage(url: url, pageIndex: i, includingIllustrations: true)
        #expect(plain.illustrations.isEmpty)
        let image = try #require(reading.illustrations.first)
        #expect(image.id == "p\(i)-illustration-\(region.captionRange.location)")
        #expect(image.sourceBounds == rect)
        let png = try #require(image.imagePNG)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        let caption = try #require(reading.paragraphSentences.first { $0.text.hasPrefix(captionText) })
        #expect(image.insertBeforeSentenceID == caption.id)
        #expect(reading.paragraphSentences.contains { $0.text.contains("reader verifies the result") })
        if i == 0 {
            #expect(plain.sentences.contains { $0.text == "The signal rises." })
            #expect(!reading.paragraphSentences.contains { $0.text == "The signal rises." })
        }
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test func pdfCaptionRegionRejectsUnverifiedTextAndRotation() throws {
    let url = try illustratedFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 2))
    let regions = try PDFCaptionRegionDetector.regions(on: page)
    #expect(regions.map(\.label) == ["图 5"])
    #expect(regions.first?.sourceBounds == nil)
    let ambiguous = try #require(document.page(at: 3))
    let candidates = try PDFCaptionRegionDetector.regions(on: ambiguous)
    #expect(candidates.map(\.label) == ["图 8", "图 9"])
    #expect(candidates.allSatisfy { $0.sourceBounds == nil })
    page.rotation = 90
    #expect(try PDFCaptionRegionDetector.regions(on: page).isEmpty)
}

private func illustratedFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 12, y: 20, width: 588, height: 750)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let value = NSAttributedString(string: value, attributes: [.init(kCTFontAttributeName as String): font])
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    context.beginPDFPage(nil)
    text("The reader verifies the result.", 70, 700)
    context.setLineWidth(1)
    context.stroke(CGRect(x: 74, y: 528, width: 274, height: 103))
    context.fill(CGRect(x: 124, y: 528, width: 25, height: 50))
    context.fill(CGRect(x: 170, y: 528, width: 25, height: 68))
    text("The signal rises.", 214, 606)
    text("Time (s).", 181, 514)
    text("Figure 1: Measured uptake.", 72, 487)
    context.endPDFPage()
    context.beginPDFPage(nil)
    text("The reader verifies the result.", 70, 700)
    text("Table 2: Sample counts.", 72, 605)
    for y in [590, 570, 508] {
        context.fill(CGRect(x: 72, y: y, width: 280, height: 1))
    }
    text("Location", 75, 575)
    text("Trials", 284, 575)
    for (y, name, value) in [(555, "Western", "31"), (539, "Southern", "27"), (522, "Eastern", "19")] {
        text(name, 75, CGFloat(y))
        text(value, 284, CGFloat(y))
    }
    context.endPDFPage()
    context.beginPDFPage(nil)
    text("Figure 3 shows the prior estimate.", 72, 660)
    text("The other values are in Table 4.", 72, 646)
    text("These measurements are also plotted in", 72, 620)
    text("Figure 7. Other checks followed.", 72, 607)
    text("Figure 5: An unavailable drawing.", 72, 480)
    text("The following paragraph describes the remaining measurements.", 72, 452)
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 72, y: 629, width: 180, height: 32))
    text("The previous paragraph ends here.", 72, 614)
    text("Figure 8: A separate result.", 72, 600)
    context.fill(CGRect(x: 72, y: 378, width: 180, height: 49))
    text("Figure 9: Ambiguous panel assignment.", 72, 357)
    context.fill(CGRect(x: 72, y: 301, width: 180, height: 42))
    context.endPDFPage()
    context.closePDF()
    return url
}
