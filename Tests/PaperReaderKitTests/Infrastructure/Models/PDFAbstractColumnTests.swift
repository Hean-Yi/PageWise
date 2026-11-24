import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import PaperReaderKit

@Test func titlePagePreviewReadsTheWholeAbstractColumnAndSkipsPublicationMetadata() throws {
    func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> PDFAbstractColumn.Line {
        .init(text: text, bounds: CGRect(x: x, y: y, width: width, height: 10))
    }
    let rows = [
        line("Abstract", x: 180, y: 440, width: 51),
        line("A local trial compared readings across two seasons.", x: 180, y: 418, width: 340),
        line("Copyright and contact information", x: 36, y: 413, width: 125),
        line("Both sites reported a smaller difference in winter.", x: 180, y: 402, width: 342),
        line("Published on October 1", x: 36, y: 401, width: 125),
        line("Unmeasured conditions could have influenced the result.", x: 180, y: 386, width: 349),
        line("Introduction", x: 180, y: 310, width: 92),
        line("The study area includes two sites.", x: 180, y: 292, width: 274),
    ]
    #expect(
        PDFAbstractColumn.text(in: rows.shuffled())
            == "A local trial compared readings across two seasons. Both sites reported a smaller difference in winter. Unmeasured conditions could have influenced the result."
    )
    #expect(PDFAbstractColumn.text(in: Array(rows.prefix(6))) == nil)
}

@Test func unlabelledTitlePageAbstractNeedsBothFrontMatterAndAnEndMarker() throws {
    func line(_ text: String, y: CGFloat) -> PDFAbstractColumn.Line {
        .init(text: text, bounds: CGRect(x: 55, y: y, width: 400, height: 10))
    }
    let prose = [
        "Local gauges sometimes disagree when measuring water near a bend in a stream.",
        "We compare three gauges under matched conditions and repeat each measurement.",
        "Across both trials, water speed accounts for most of the observed difference.",
    ]
    let rows = [
        line("Measuring a bend in a stream", y: 700),
        line("P. Fields and M. Lane", y: 670),
        line("Department of Hydrology", y: 658),
        line(prose[0], y: 625), line(prose[1], y: 612), line(prose[2], y: 599),
        line("Correspondence: water@example.org", y: 570),
        line("1. Introduction", y: 540),
        line("The introduction provides different background.", y: 519),
    ]
    #expect(PDFAbstractColumn.text(in: rows, titlePage: true) == prose.joined(separator: " "))
    #expect(PDFAbstractColumn.text(in: rows, titlePage: false) == nil)
    #expect(PDFAbstractColumn.text(in: Array(rows[3...]), titlePage: true) == nil)
    #expect(PDFAbstractColumn.text(in: Array(rows.prefix(7)), titlePage: true) == nil)
    #expect(PDFAbstractColumn.text(in: Array(rows.prefix(3)) + Array(rows.suffix(2)), titlePage: true) == nil)
}

@Test func unlabelledPDFPreservesCompleteSentenceTranslationAnchors() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: file) }
    let consumer = try #require(CGDataConsumer(url: file as CFURL))
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    pdf.beginPDFPage(nil)
    func text(_ string: String, at y: CGFloat, size: CGFloat = 10) {
        let value = NSAttributedString(
            string: string,
            attributes: [
                .init(kCTFontAttributeName as String): CTFontCreateWithName("Times-Roman" as CFString, size, nil)
            ])
        pdf.textMatrix = .identity
        pdf.textPosition = CGPoint(x: 60, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), pdf)
    }
    text("Measuring water speed", at: 745, size: 18)
    text("Mira Lane and Pat Fields", at: 720)
    text("Local University", at: 705)
    let sentences = [
        "Local gauges disagree when measuring water near a bend in a stream.",
        "We compare three gauges under matched conditions and repeat each measurement.",
        "Water speed accounts for most of the observed difference between the gauges.",
    ]
    for (index, line) in sentences.enumerated() { text(line, at: 665 - CGFloat(index) * 13) }
    text("Correspondence: water@example.org", at: 588)
    text("1. Introduction", at: 554, size: 15)
    text("This introduction gives historical background.", at: 530)
    pdf.endPDFPage()
    pdf.closePDF()

    let result = try PDFAbstractExtractor.extract(url: file, pages: 1)
    #expect(result.parts.map(\.text) == sentences)
    #expect(result.sentences.map(\.id) == result.parts.map(\.key))
}

@Test(arguments: ["Date: October 16, 2024", "Correspondence: P. Fields", "Figure 1: Comparison of the sites."])
func abstractStopsBeforeTitlePageDetails(_ boundary: String) throws {
    let text = "Two sites showed similar results. Figure 1 shows the comparison."
    let parts = ["Abstract", text, boundary, "Unrelated details."]
        .enumerated().map { AbstractPassage.Part(text: $1, paragraph: "p", key: String($0)) }
    let result = try #require(AbstractPassage.locate(parts))
    #expect(result.closed)
    #expect(result.parts.map(\.text) == [text])
}
