import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

private let cropCaption = "Figure 1. Original recovery caption."

@Test(arguments: [false, true]) func figurePixelsUseOriginalPageCoordinates(offset: Bool) throws {
    let fixture = try cropFixture(offset: offset)
    let page = try #require(fixture.page(at: 0))
    let pixels = try #require(PDFFigurePixels(page: page))
    let ink = try #require(pixels.inkBounds(in: CGRect(x: 60, y: 340, width: 230, height: 250)))
    #expect(abs(ink.minX - 70) < 2)
    #expect(abs(ink.minY - 350) < 2)
    #expect(abs(ink.maxX - 280) < 2)
    #expect(abs(ink.maxY - 580) < 2)
}

@Test(arguments: [false, true]) func cropIncludesPanelsLabelsAndExcludesOtherColumn(multiplePanels: Bool) throws {
    let fixture = try cropFixture(multiplePanels: multiplePanels, remoteLegend: true)
    let page = try #require(fixture.page(at: 0))
    let recovery = try #require(try PDFFigureCropper.recover(caption: cropCaption, from: page))
    let expected = CGRect(x: 70, y: 350, width: 210, height: 318)
    #expect(recovery.bounds.insetBy(dx: -2, dy: -2).contains(expected))
    #expect(recovery.bounds.maxX < 310)
    #expect(recovery.bounds.minY > 320)
    #expect(recovery.bounds.maxY < 700)
    #expect(recovery.coverageText.contains("UNCHANGED_LABEL"))
    #expect(recovery.coverageText.contains("REMOTE LEGEND"))
    #expect(!recovery.coverageText.contains("neighboring"))
    #expect(!recovery.coverageText.contains("Figure 1"))
}

@Test(arguments: ["missing", "duplicate", "paragraph", "textOnly", "rotated"])
func uncertainFigureCropIsRejected(reason: String) throws {
    let fixture = try cropFixture(
        duplicateCaption: reason == "duplicate", paragraphBetween: reason == "paragraph", textOnly: reason == "textOnly"
    )
    let page = try #require(fixture.page(at: 0))
    if reason == "rotated" { page.rotation = 90 }
    let recovery = try PDFFigureCropper.recover(
        caption: reason == "missing" ? "Figure 99. Wrong caption." : cropCaption, from: page)
    #expect(recovery == nil)
}

@Test @MainActor func failedHTMLImageRecoversFromPDFAndKeepsCaptionTranslation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.pdf")
    #expect(try cropFixture(reverseCaption: true).write(to: source))
    let original = try Data(contentsOf: source)
    struct MissingImage: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw ReaderError.message("Fixture image unavailable")
        }
    }
    let blocks = try await HTMLPaperParser(transport: MissingImage()).parse(
        Data(
            "<article class='ltx_document'><figure><img src='missing'><figcaption>\(cropCaption)</figcaption></figure></article>"
                .utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    let paper = try await PDFImporter(root: directory).importPDF(at: source, structuredBlocks: blocks)
    let block = try #require(paper.blocks.first)
    #expect(block.hasImageFailure == false)
    #expect(block.preservesSourcePage != true)
    #expect(block.sourcePage == 0)
    #expect(block.richContent?.translationInput == cropCaption)
    #expect(block.richContent?.html.contains("data:image/png;base64,") == true)
    #expect(block.imageWarnings?.contains { $0.contains("裁剪补全") } == true)
    let pages = try await StructuredPageRenderer().render(
        [BilingualBlock(block: block, translation: "图 1：原创裁剪测试图。")], to: directory.appendingPathComponent("pages"),
        originalURL: source)
    let result = try #require(
        PDFDocument(url: directory.appendingPathComponent("pages").appendingPathComponent(pages[0].relativePath)))
    #expect(result.string?.contains(cropCaption) == true)
    let renderedText = try #require(result.string)
    #expect(renderedText.filter { !$0.isWhitespace }.contains("原创裁剪测试图"))
    #expect(try Data(contentsOf: source) == original)
}

private func cropFixture(
    multiplePanels: Bool = false, duplicateCaption: Bool = false, paragraphBetween: Bool = false,
    textOnly: Bool = false, offset: Bool = false, reverseCaption: Bool = false, remoteLegend: Bool = false
) throws -> PDFDocument {
    let bytes = NSMutableData()
    var box = CGRect(x: offset ? 20 : 0, y: offset ? 30 : 0, width: 612, height: 792)
    let consumer = try #require(CGDataConsumer(data: bytes))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 10) {
        context.textPosition = CGPoint(x: x, y: y)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let line = NSAttributedString(
            string: value,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, size, nil)
            ])
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
    }
    context.beginPDFPage(nil)
    text("This neighboring paragraph must remain outside the recovered figure region.", x: 50, y: 720)
    if !textOnly {
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
        if multiplePanels {
            context.fill(CGRect(x: 70, y: 350, width: 210, height: 80))
            context.fill(CGRect(x: 70, y: 500, width: 210, height: 80))
        } else {
            context.fill(CGRect(x: 70, y: 350, width: 210, height: 230))
        }
        context.fill(CGRect(x: 350, y: 360, width: 190, height: 210))
        for i in 0..<20 { context.fill(CGRect(x: CGFloat(45 + i * 8), y: 680, width: 0.5, height: 0.5)) }
    }
    text("UNCHANGED_LABEL", x: 80, y: 595)
    if remoteLegend {
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 90, y: 640, width: 12, height: 12))
        text("REMOTE LEGEND", x: 115, y: 655)
    }
    if reverseCaption {
        text("recovery caption.", x: 60, y: 286)
        text("Original", x: 110, y: 300)
        text("Figure 1.", x: 60, y: 300)
    } else {
        text(cropCaption, x: 60, y: 300)
    }
    if duplicateCaption { text(cropCaption, x: 60, y: 200) }
    if paragraphBetween {
        text("This intervening paragraph makes the association uncertain and must be rejected.", x: 50, y: 330, size: 8)
    }
    text("This neighboring paragraph below the caption must also remain outside the crop.", x: 50, y: 100)
    context.endPDFPage()
    context.closePDF()
    return try #require(PDFDocument(data: bytes as Data))
}
