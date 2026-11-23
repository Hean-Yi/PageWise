import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func wrappedEnglishPreservesCompoundsSuspendedHyphensAndOriginalPunctuation() {
    #expect(
        PDFEnglishLineBreak.separator(after: "We compare short-", before: "and long-term memory.", spellings: [])
            == .space)
    #expect(PDFEnglishLineBreak.separator(after: "The residual is 3 -", before: "2 units.", spellings: []) == .space)
    #expect(
        PDFEnglishLineBreak.separator(after: "It works in real-", before: "time.", spellings: ["real-time"]) == .joined)
    #expect(
        PDFEnglishLineBreak.separator(after: "We use non‑", before: "linear terms.", spellings: ["nonlinear"])
            == .joined)
    #expect(PDFEnglishLineBreak.separator(after: "Uniquely narav-", before: "otic drift.", spellings: []) == .joined)
    #expect(PDFEnglishLineBreak.separator(after: "The exam\u{ad}", before: "ple ends.", spellings: []) == .removeHyphen)
    #expect(
        PDFEnglishLineBreak.separator(after: "Earlier experi‐", before: "mental data.", spellings: ["experimental"])
            == .removeHyphen)
    #expect(PDFEnglishLineBreak.separator(after: "Trials (", before: "in both phases).", spellings: []) == .joined)
}

@Test func pdfRecoversPaintedWordSpacesWithoutInventingWordsOrLosingSourceOffsets() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    func draw(_ text: String, after terms: [String], at y: CGFloat) {
        let line = NSMutableAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        for term in terms {
            let range = (text as NSString).range(of: term)
            line.addAttribute(
                .init(kCTKernAttributeName as String), value: 1.5,
                range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
        context.textPosition = CGPoint(x: 50, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
    }
    draw("The boatsdriftalongtheshore past the lighthouse.", after: ["boats", "drift", "along", "the"], at: 550)
    draw(
        "The boatsdriftalongthemaravonic coast each evening.",
        after: ["boats", "drift", "along", "the"], at: 530)
    let second = "The boats drift along the shore. Our identifier boatsdriftalongtheshore is literal."
    context.textPosition = CGPoint(x: 50, y: 510)
    CTLineDraw(
        CTLineCreateWithAttributedString(
            NSAttributedString(string: second, attributes: [.init(kCTFontAttributeName as String): font])), context)
    context.endPDFPage()
    context.closePDF()

    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    let sentences = try PDFSentenceExtractor.extract(url: url, pageIndex: 0)
    let first = try #require(sentences.first)
    #expect(first.text == "The boats drift along the shore past the lighthouse.")
    #expect(first.rects.count == 1)
    let sourceLine = try #require(page.string?.split(separator: "\n").first)
    #expect(first.characterRanges.compactMap { page.selection(for: $0)?.string }.joined() == String(sourceLine))
    #expect(sentences.contains { $0.text == "The boats drift along the maravonic coast each evening." })
    #expect(sentences.last?.text == "Our identifier boatsdriftalongtheshore is literal.")
}
