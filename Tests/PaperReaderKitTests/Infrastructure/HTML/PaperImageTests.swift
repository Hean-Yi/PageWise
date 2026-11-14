import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import PaperReaderKit

private let imageSource = URL(string: "https://arxiv.org/html/2401.00001v1")!
private struct ImageFixtureTransport: HTTPTransport {
    var resources: [String: Data] = [:]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        guard let data = resources[url.lastPathComponent] else { throw ReaderError.message("Fixture image missing") }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private let vectorFigure = """
    <svg xmlns="http://www.w3.org/2000/svg" width="900" height="240" viewBox="0 0 900 240">
    <defs><linearGradient id="paint"><stop offset="0" stop-color="#387e82"/><stop offset="1" stop-color="#b2dcb8"/></linearGradient>
    <clipPath id="clip"><rect width="900" height="240" rx="12"/></clipPath><path id="line" d="M20 190 L200 70 L400 120 L600 30 L880 80"/></defs>
    <g clip-path="url(#clip)"><rect width="900" height="240" fill="url(#paint)"/>
    <use href="#line" fill="none" stroke="#163b45" stroke-width="4"/><text x="20" y="40" font-size="24">VECTOR_LABEL</text></g>
    </svg>
    """

@Test func allSVGEmbeddingModesPreserveStaticStructure() async throws {
    let external = vectorFigure.replacingOccurrences(
        of: "<g clip-path", with: "<script>alert(1)</script><g onclick='bad()' clip-path")
    let parser = HTMLPaperParser(transport: ImageFixtureTransport(resources: ["figure.bin": Data(external.utf8)]))
    for element in [
        "<img src='2401.00001v1/figure.bin'>",
        "<object type='image/svg+xml' data='2401.00001v1/figure.bin'></object>",
        "<embed src='2401.00001v1/figure.bin'>", vectorFigure,
    ] {
        let blocks = try await parser.parse(
            Data(
                "<article class='ltx_document'><figure>\(element)<figcaption>Figure caption</figcaption></figure></article>"
                    .utf8), at: imageSource)
        let block = try #require(blocks.first)
        #expect(block.hasImageFailure == false)
        #expect(block.richContent?.isFigure == true)
        #expect(block.richContent?.imageSizes == [PaperImageSize(width: 900, height: 240)])
        let html = try #require(block.richContent?.html)
        let encoded = try #require(html.components(separatedBy: "base64,").last?.components(separatedBy: "\"").first)
        let xmlBytes = try #require(Data(base64Encoded: encoded))
        let xml = try #require(String(data: xmlBytes, encoding: .utf8))
        #expect(xml.contains("linearGradient"))
        #expect(xml.contains("clipPath"))
        #expect(xml.contains("viewBox"))
        #expect(xml.contains("href=\"#line\""))
        #expect(!xml.contains("<script"))
        #expect(!xml.contains("onclick"))
        #expect(block.text == "Figure caption")
        #expect(block.richContent?.translationInput == "Figure caption")
        #expect(block.richContent?.imageTextForCoverage?.contains("VECTOR_LABEL") == true)
    }
}

@Test func missingOrUnsafeImagesStayLocalAndNeverEnterTranslation() async throws {
    let parser = HTMLPaperParser(transport: ImageFixtureTransport())
    for resource in ["https://example.com/private.png", "2401.00001v1/missing.svg", "data:image/svg+xml;base64,broken"]
    {
        let html =
            "<article class='ltx_document'><p>Keep this paragraph.</p><figure><img src='\(resource)'><figcaption>Original caption.</figcaption></figure><p>Keep this conclusion.</p></article>"
        let blocks = try await parser.parse(Data(html.utf8), at: imageSource)
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "Keep this paragraph.")
        #expect(blocks[2].text == "Keep this conclusion.")
        #expect(blocks[1].hasImageFailure == true)
        #expect(blocks[1].richContent?.html.contains("图片未能转换") == true)
        #expect(blocks[1].richContent?.translationInput == "Original caption.")
        #expect(blocks[1].sourcePage == -1)
    }
}

@Test func nestedSVGImagesAreLocalizedAndExternalStylesRejected() async throws {
    let png = try rasterFixture(type: "public.png")
    let svg =
        "<svg width='100' height='60' xmlns='http://www.w3.org/2000/svg'><image href='nested.png' width='100' height='60'/></svg>"
    let loader = PaperImageLoader(
        source: imageSource,
        transport: ImageFixtureTransport(resources: ["figure.svg": Data(svg.utf8), "nested.png": png]))
    let result = try await loader.load("2401.00001v1/figure.svg")
    let xmlBytes = try #require(Data(base64Encoded: result[0].dataURI.components(separatedBy: ",")[1]))
    let xml = try #require(String(data: xmlBytes, encoding: .utf8))
    #expect(xml.contains("data:image/png;base64,"))
    #expect(!xml.contains("nested.png"))
    for bad in [
        "<use href='https://example.com/remote.svg#x'/>", "<style>@import 'remote.css';</style>",
        "<rect fill='url(https://example.com/paint)'/>", "<use href='#absent'/>",
    ] {
        #expect(throws: (any Error).self) {
            try SVGImageDocument.parse(Data("<svg width='10' height='10'>\(bad)</svg>".utf8))
        }
    }
    let animated = try SVGImageDocument.parse(
        Data(
            "<svg width='10' height='10'><rect width='10' height='10'><animate attributeName='x' to='9'/></rect></svg>"
                .utf8))
    #expect(animated.isAnimated)
    let staticURI = try animated.dataURI(replacing: [:])
    let staticBytes = try #require(Data(base64Encoded: staticURI.components(separatedBy: ",")[1]))
    #expect(!String(decoding: staticBytes, as: UTF8.self).contains("<animate"))
}

@Test func failedFigureUsesOnlyUniquelyMatchedOriginalPage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("fixture.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 50, y: 700)
    let text = NSAttributedString(
        string: "Unique figure caption",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString, 14, nil)
        ])
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let figureLabels = [
        "alpha bravo charlie delta echo foxtrot golf hotel", "india juliet kilo lima mike november oscar papa",
        "quebec romeo sierra tango uniform victor whiskey xray",
    ]
    for (index, labels) in figureLabels.enumerated() {
        context.textPosition = CGPoint(x: 50, y: 650 - index * 30)
        CTLineDraw(
            CTLineCreateWithAttributedString(
                NSAttributedString(string: labels, attributes: text.attributes(at: 0, effectiveRange: nil))), context)
    }
    context.strokeEllipse(in: CGRect(x: 50, y: 300, width: 300, height: 200))
    context.endPDFPage()
    context.closePDF()
    let linkedDocument = try #require(PDFDocument(url: source))
    let link = PDFAnnotation(bounds: CGRect(x: 50, y: 690, width: 100, height: 20), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.com")
    linkedDocument.page(at: 0)?.addAnnotation(link)
    #expect(linkedDocument.write(to: source))
    let parser = HTMLPaperParser(transport: ImageFixtureTransport())
    let blocks = try await parser.parse(
        Data(
            "<article class='ltx_document'><figure><img src='bad'><figcaption>Unique figure caption</figcaption></figure><figure><img src='bad'><figcaption>Unmatched figure caption</figcaption></figure></article>"
                .utf8), at: imageSource)
    let paper = try await PDFImporter(root: directory).importPDF(at: source, structuredBlocks: blocks)
    try #require(paper.blocks.count == 2)
    #expect(paper.blocks[0].sourcePage == 0)
    #expect(paper.blocks[0].preservesSourcePage == true)
    #expect(paper.blocks[0].richContent == nil)
    #expect(paper.blocks[1].sourcePage == -1)
    #expect(paper.blocks[1].preservesSourcePage != true)
    #expect(paper.blocks[1].richContent?.html.contains("图片未能转换") == true)
    #expect(paper.warnings.contains { $0.contains("整页") })
}

@Test func svgLabelsExplainPDFCoverageWithoutBecomingTranslationOrEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("labels.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
    let lines = [
        "Ordinary paragraph remains here.", "alpha bravo charlie delta echo foxtrot golf hotel",
        "india juliet kilo lima mike november oscar papa", "quebec romeo sierra tango uniform victor whiskey xray",
    ]
    context.beginPDFPage(nil)
    for (index, line) in lines.enumerated() {
        context.textPosition = CGPoint(x: 50, y: 700 - index * 30)
        let value = NSAttributedString(
            string: line,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, 12, nil)
            ])
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    context.endPDFPage()
    context.closePDF()
    let linkedDocument = try #require(PDFDocument(url: source))
    let link = PDFAnnotation(bounds: CGRect(x: 50, y: 690, width: 100, height: 20), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.com")
    linkedDocument.page(at: 0)?.addAnnotation(link)
    #expect(linkedDocument.write(to: source))
    let localAnalysis = try PDFProcessor.extract(from: linkedDocument)
    #expect(!localAnalysis.warnings.contains { $0.contains("已有批注") })
    let parser = HTMLPaperParser(transport: ImageFixtureTransport())
    for complete in [true, false] {
        let labels = complete ? lines.dropFirst().joined(separator: " ") : "unrelated"
        let blocks = try await parser.parse(
            Data(
                "<article class='ltx_document'><p>\(lines[0])</p><figure><svg width='500' height='200'><text x='0' y='20'>\(labels)</text></svg><figcaption>Caption.</figcaption></figure></article>"
                    .utf8), at: imageSource)
        #expect(blocks[1].text == "Caption.")
        #expect(blocks[1].richContent?.translationInput == "Caption.")
        let paper = try await PDFImporter(root: directory).importPDF(at: source, structuredBlocks: blocks)
        #expect(paper.blocks.contains { $0.richContent != nil } == complete)
    }
    let annotated = try #require(PDFDocument(url: source))
    annotated.page(at: 0)?.addAnnotation(
        PDFAnnotation(bounds: CGRect(x: 50, y: 650, width: 100, height: 20), forType: .highlight, withProperties: nil))
    #expect(annotated.write(to: source))
    let blocks = try await parser.parse(
        Data("<article class='ltx_document'><p>\(lines.joined(separator: " "))</p></article>".utf8), at: imageSource)
    let protectedPaper = try await PDFImporter(root: directory).importPDF(at: source, structuredBlocks: blocks)
    #expect(protectedPaper.blocks.allSatisfy { $0.richContent == nil })
    #expect(!protectedPaper.canReflow)
}

@Test func rasterOrientationAlphaAnimationAndMultiplePages() async throws {
    let loader = PaperImageLoader(source: imageSource, transport: ImageFixtureTransport())
    func load(_ bytes: Data) async throws -> [PaperImage] {
        try await loader.load("data:application/octet-stream;base64," + bytes.base64EncodedString())
    }
    let oriented = try await load(rasterFixture(type: "public.tiff", orientation: 6))
    #expect(oriented[0].width == 20 && oriented[0].height == 40)
    let transparent = try await load(rasterFixture(type: "public.png"))
    let pngBytes = try #require(Data(base64Encoded: transparent[0].dataURI.components(separatedBy: ",")[1]))
    let source = try #require(CGImageSourceCreateWithData(pngBytes as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    #expect(properties[kCGImagePropertyHasAlpha as String] as? Bool == true)
    let animated = try await load(rasterFixture(type: "com.compuserve.gif", pages: 2))
    #expect(animated.count == 1)
    #expect(animated[0].notices.contains { $0.contains("首帧") })
    let multipage = try await load(rasterFixture(type: "public.tiff", pages: 2))
    #expect(multipage.count == 2)
    let pdfData = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 40, height: 20)
    let consumer = try #require(CGDataConsumer(data: pdfData))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<2 {
        context.beginPDFPage(nil)
        context.fill(box)
        context.endPDFPage()
    }
    context.closePDF()
    let pdfImages = try await load(pdfData as Data)
    #expect(pdfImages.count == 2)
    #expect(pdfImages.allSatisfy { $0.width == 120 && $0.height == 60 })
}

@Test @MainActor func svgFixedPagesRemainVectorAndGiveWideAndTallFiguresRoom() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tall = vectorFigure.replacingOccurrences(
        of: "width=\"900\" height=\"240\" viewBox=\"0 0 900 240\"",
        with: "width=\"400\" height=\"1600\" viewBox=\"0 0 900 240\"")
    let parser = HTMLPaperParser(transport: ImageFixtureTransport())
    for (svg, wide) in [(vectorFigure, true), (tall, false)] {
        let blocks = try await parser.parse(
            Data(
                "<article class='ltx_document'><figure>\(svg)<figcaption>Complete figure caption.</figcaption></figure></article>"
                    .utf8), at: imageSource)
        let pages = try await StructuredPageRenderer().render(
            blocks.map { BilingualBlock(block: $0, translation: "完整图注。") }, to: directory,
            originalURL: directory.appendingPathComponent("unused.pdf"))
        #expect(pages.count == 1)
        let document = try #require(PDFDocument(url: directory.appendingPathComponent(pages[0].relativePath)))
        let page = try #require(document.page(at: 0))
        #expect(document.string?.contains("Complete figure caption") == true)
        #expect(document.string?.contains("完整图注") == true)
        #expect(wide ? page.bounds(for: .mediaBox).width > 612 : page.bounds(for: .mediaBox).height > 1600)
        // A rasterized SVG loses its labels from the PDF text layer.
        #expect(document.string?.contains("VECTOR_LABEL") == true)
    }
}

@Test @MainActor func multiPanelImagesKeepOrderAcrossFixedPages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let labels = ["PANEL_ONE", "PANEL_TWO", "PANEL_THREE"]
    let panels = labels.map {
        "<svg width='400' height='1800'><rect width='400' height='1800' fill='#e4eee7'/><text x='20' y='100' font-size='30'>\($0)</text></svg>"
    }.joined()
    let blocks = try await HTMLPaperParser(transport: ImageFixtureTransport()).parse(
        Data(
            "<article class='ltx_document'><figure>\(panels)<figcaption>Final panel caption.</figcaption></figure></article>"
                .utf8), at: imageSource)
    let pages = try await StructuredPageRenderer().render(
        blocks.map { BilingualBlock(block: $0, translation: nil) }, to: directory,
        originalURL: directory.appendingPathComponent("unused.pdf"))
    #expect(pages.count >= 2)
    let text = pages.compactMap { PDFDocument(url: directory.appendingPathComponent($0.relativePath))?.string }.joined()
    for label in labels { #expect(text.components(separatedBy: label).count == 2) }
    #expect(text.contains("Final panel caption"))
    let positions = try labels.map { try #require(text.range(of: $0)?.lowerBound) }
    #expect(positions == positions.sorted())
}

private func rasterFixture(type: String, pages: Int = 1, orientation: Int = 1) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 0.5))
    context.fill(CGRect(x: 5, y: 5, width: 30, height: 10))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, pages, nil))
    for _ in 0..<pages {
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
}
