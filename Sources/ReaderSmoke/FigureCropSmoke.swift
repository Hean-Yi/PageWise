import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PaperReaderKit

#if os(macOS)
    import AppKit
#endif

@MainActor enum FigureCropSmoke {
    private struct MissingFigure: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw ReaderError.message("Original fixture deliberately omits the HTML image")
        }
    }

    static func run(in root: URL) async throws {
        let source = root.appendingPathComponent("Crop-source.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(source as CFURL, mediaBox: &box, nil) else {
            throw ReaderError.message("Cannot create crop fixture")
        }
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 12) {
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.textPosition = CGPoint(x: x, y: y)
            let line = NSAttributedString(
                string: value,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString, size, nil)
                ])
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        let before = "The original panels and their labels should survive a missing HTML image."
        let after = "This paragraph is ordinary body text and must stay outside the recovered figure."
        let caption = "Figure 1. Two original panels."
        context.beginPDFPage(nil)
        text(before, x: 50, y: 730, size: 11)
        for (y, color) in [(350.0, 0.4), (500.0, 0.6)] {
            context.setFillColor(CGColor(red: 0.2, green: color, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 70, y: y, width: 220, height: 100))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(3)
            context.move(to: CGPoint(x: 85, y: y + 20))
            context.addLine(to: CGPoint(x: 140, y: y + 70))
            context.addLine(to: CGPoint(x: 200, y: y + 40))
            context.addLine(to: CGPoint(x: 275, y: y + 85))
            context.strokePath()
        }
        text("UNCHANGED LABEL", x: 80, y: 615, size: 15)
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 70, y: 655, width: 12, height: 12))
        text("Legend: original colors", x: 90, y: 657)
        text(caption, x: 60, y: 300)
        text(after, x: 50, y: 160, size: 11)
        context.endPDFPage()
        context.closePDF()
        let original = try Data(contentsOf: source)
        let html =
            "<article class='ltx_document'><p>\(before)</p><figure><img src='missing'><figcaption>\(caption)</figcaption></figure><p>\(after)</p></article>"
        let blocks = try await HTMLPaperParser(transport: MissingFigure()).parse(
            Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
        let paper = try await PDFImporter(root: root).importPDF(at: source, structuredBlocks: blocks)
        guard let figure = paper.blocks.first(where: { $0.richContent?.isFigure == true }),
            figure.hasImageFailure == false,
            figure.preservesSourcePage != true, figure.richContent?.translationInput == caption
        else { throw ReaderError.message("Figure crop fixture was not recovered") }
        let directory = root.appendingPathComponent("RecoveredFigure")
        let pages = try await StructuredPageRenderer().render(
            [BilingualBlock(block: figure, translation: "图 1：两个原创面板。图内文字保留原样。")], to: directory, originalURL: source)
        guard try Data(contentsOf: source) == original else { throw ReaderError.message("Original PDF changed") }
        #if os(macOS)
            for (label, url) in [("crop-source", source)]
                + pages.enumerated().map({
                    ("crop-recovered-\($0.offset + 1)", directory.appendingPathComponent($0.element.relativePath))
                })
            {
                guard let page = PDFDocument(url: url)?.page(at: 0),
                    let tiff = page.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox).tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { throw ReaderError.message("Cannot render crop verification image") }
                try png.write(to: root.appendingPathComponent(label + ".png"))
            }
        #endif
        print(
            "PASS: missing image recovered from original PDF pixels, both panels and original labels retained, caption translated"
        )
    }
}
