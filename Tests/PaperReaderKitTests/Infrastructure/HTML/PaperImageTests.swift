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

@Test func svgForeignObjectPreservesCodeMathAndNestedSVGNamespaces() throws {
    let source = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="160">
        <foreignObject width="320" height="160"><div><pre>value = memory * mask</pre>
        <math><semantics><mfrac><mi>x</mi><mn>2</mn></mfrac><annotation encoding="application/x-tex">DO_NOT_DUPLICATE</annotation></semantics></math>
        <svg width="10" height="10"><path d="M0 0L10 10"/></svg></div></foreignObject></svg>
        """
    let image = try SVGImageDocument.parse(Data(source.utf8))
    let uri = try image.dataURI(replacing: [:])
    let payload = try #require(uri.split(separator: ",", maxSplits: 1).last)
    let data = try #require(Data(base64Encoded: String(payload)))
    let output = try #require(String(data: data, encoding: .utf8))
    #expect(output.contains("<pre xmlns=\"http://www.w3.org/1999/xhtml\">"))
    #expect(output.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\">"))
    #expect(output.components(separatedBy: "xmlns=\"http://www.w3.org/2000/svg\"").count == 3)
    #expect(!output.contains("DO_NOT_DUPLICATE"))
}

private actor UnavailableImageConnection: HTTPTransport {
    var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        throw URLError(.secureConnectionFailed)
    }
}

@Test func brokenImageConnectionIsNotRetriedForEveryFigure() async throws {
    let transport = UnavailableImageConnection()
    let loader = PaperImageLoader(source: imageSource, transport: transport)
    for name in ["one.svg", "two.svg", "three.svg"] {
        await #expect(throws: URLError.self) {
            try await loader.load("2401.00001v1/" + name)
        }
    }
    #expect(await transport.requests == 1)
    // The failure is scoped to this import; a later retry gets a fresh connection attempt.
    let retry = PaperImageLoader(source: imageSource, transport: transport)
    await #expect(throws: URLError.self) { try await retry.load("2401.00001v1/one.svg") }
    #expect(await transport.requests == 2)
}
