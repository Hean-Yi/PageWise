import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

private struct NoHTMLNetwork: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ReaderError.message("Unexpected network request")
    }
}

private let sourceURL = URL(string: "https://arxiv.org/html/2401.00001v1")!

@Test func structuredHTMLPreservesMathAndRejectsActiveOrMissingContent() async throws {
    let parser = HTMLPaperParser(transport: NoHTMLNetwork())
    let html = """
        <article class="ltx_document"><h1>Original fixture</h1>
        <p onclick="fetch('https://example.com')">A query <math alttext="q_i"><msub><mi>q</mi><mi>i</mi></msub></math> selects evidence.</p>
        <table><tr><th>Method</th><th>Value</th></tr><tr><td>Local</td><td>42</td></tr></table>
        <script>window.bad = true</script></article>
        """
    let blocks = try await parser.parse(Data(html.utf8), at: sourceURL)
    #expect(blocks.count == 3)
    #expect(blocks[1].text.contains("q_i"))
    let rich = try #require(blocks[1].richContent)
    #expect(rich.html.contains("<msub>"))
    #expect(!rich.html.contains("onclick"))
    #expect(rich.translationInput.contains("[[MATH_1]]"))
    #expect(blocks.allSatisfy { $0.sourcePage == -1 })
    try rich.validate("查询 [[MATH_1]] 选择证据。")
    #expect(throws: ReaderError.self) { try rich.validate("查询选择证据。") }
    #expect(throws: ReaderError.self) { try rich.validate("[[MATH_1]] [[MATH_1]]") }
    #expect(rich.readableTranslation("查询 [[MATH_1]]") == "查询 q_i")
    for content in [
        "<canvas>lost drawing</canvas>", "<img src='https://example.com/private.png'>", "<img src='x1.png'>",
        "<p class='ltx_ERROR'>lost equation</p>",
    ] {
        await #expect(throws: (any Error).self) {
            try await parser.parse(Data("<article class='ltx_document'>\(content)</article>".utf8), at: sourceURL)
        }
    }
}

@Test @MainActor func richFixedPagesPreserveTextMathAndExistingBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let html = """
        <article class="ltx_document"><p>Evidence connects a query
        <math alttext="q_i"><msub><mi>q</mi><mi>i</mi></msub></math>
        to a result.</p><table><tr><th>Method</th><th>Score</th></tr><tr><td>Local</td><td>42</td></tr></table></article>
        """
    let blocks = try await HTMLPaperParser(transport: NoHTMLNetwork()).parse(Data(html.utf8), at: sourceURL)
    let renderer = StructuredPageRenderer()
    let first = try await renderer.render(
        [BilingualBlock(block: blocks[0], translation: "证据将查询 [[MATH_1]] 与结果联系起来。")], to: directory,
        originalURL: directory.appendingPathComponent("unused.pdf"))
    #expect(first.count == 1)
    let pageURL = directory.appendingPathComponent(try #require(first.first).relativePath)
    let bytes = try Data(contentsOf: pageURL)
    let document = try #require(PDFDocument(data: bytes))
    #expect(document.string?.contains("Evidence") == true)
    #expect(document.string?.contains("证据") == true)
    #expect(document.page(at: 0)?.bounds(for: .mediaBox).width == 612)
    _ = try await renderer.render(
        [BilingualBlock(block: blocks[1], translation: nil)], to: directory,
        originalURL: directory.appendingPathComponent("unused.pdf"))
    #expect(try Data(contentsOf: pageURL) == bytes)
    #expect(first[0].blockIDs == [blocks[0].id])
}

@Test @MainActor func oversizedHTMLFailsWithoutLeavingPublishedFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rows = String(repeating: "<mi>W</mi>", count: 200)
    let blocks = try await HTMLPaperParser(transport: NoHTMLNetwork()).parse(
        Data("<article class='ltx_document'><math><mrow>\(rows)</mrow></math></article>".utf8), at: sourceURL)
    await #expect(throws: (any Error).self) {
        try await StructuredPageRenderer().render(
            [BilingualBlock(block: blocks[0], translation: nil)], to: directory,
            originalURL: directory.appendingPathComponent("unused.pdf"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test @MainActor func mixedPDFKeepsComplexPageGeometryAndSelectableText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("input.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil))
    for index in 0..<3 {
        context.beginPDFPage(nil)
        let value = NSAttributedString(
            string: index == 0
                ? "Reliable prose can be translated and reflowed." : "An important vector figure remains intact.",
            attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
        context.textPosition = CGPoint(x: 54, y: 720)
        if index < 2 { CTLineDraw(CTLineCreateWithAttributedString(value), context) }
        if index > 0 { context.strokeEllipse(in: CGRect(x: 60, y: 400, width: 240, height: 140)) }
        context.endPDFPage()
    }
    context.closePDF()
    let originalBytes = try Data(contentsOf: source)
    let root = directory.appendingPathComponent("library")
    let paper = try await PDFImporter(root: root).importPDF(at: source, preservingComplexPages: true)
    #expect(paper.canReflow)
    #expect(paper.blocks.contains { $0.preservesSourcePage == true && $0.sourcePage == 1 })
    #expect(paper.blocks.contains { $0.preservesSourcePage == true && $0.sourcePage == 2 && $0.text.isEmpty })
    let pages = try await StructuredPageRenderer().render(
        paper.blocks.map { BilingualBlock(block: $0, translation: $0.preservesSourcePage == true ? nil : "可靠正文。") },
        to: directory.appendingPathComponent("pages"), originalURL: root.appendingPathComponent(paper.originalPath))
    let preserved = try #require(pages.first { $0.sourcePage == 1 })
    let copied = try #require(
        PDFDocument(url: directory.appendingPathComponent("pages").appendingPathComponent(preserved.relativePath)))
    let original = try #require(PDFDocument(url: source))
    #expect(copied.page(at: 0)?.string == original.page(at: 1)?.string)
    #expect(copied.page(at: 0)?.bounds(for: .mediaBox) == original.page(at: 1)?.bounds(for: .mediaBox))
    #expect(try pixels(of: #require(copied.page(at: 0))) == pixels(of: #require(original.page(at: 1))))
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == originalBytes)
}

@Test func cleanupRetainsCommittedAndLegacyPagesOnlyRemovesOwnedOrphans() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var paper = Paper(
        title: "Original fixture", digest: "fixture", originalPath: "", pageCount: 1, blocks: [], warnings: [],
        canReflow: true)
    let prefix = "Papers/\(paper.id.uuidString)/translated/"
    let directory = root.appendingPathComponent(prefix)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let keep = "html-\(UUID().uuidString).pdf"
    let orphan = "html-\(UUID().uuidString).pdf"
    for name in [keep, orphan, "user.pdf"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    paper.translatedPages = [PageArtifact(blockIDs: [], sourcePage: 0, relativePath: prefix + keep)]
    try ReflowArtifactCleanup.removeUncommittedFiles(in: root, papers: [paper])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [keep, "user.pdf"])
}

@Test @MainActor func longStructuredParagraphAndTableKeepEveryRowAcrossPages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prose = (0..<180).map { "Sentence\($0) describes how evidence supports a local query." }.joined(separator: " ")
    let rows = (0..<60).map { "<tr><td>Row\($0)</td><td>Value\($0)</td></tr>" }.joined()
    let html = "<article class='ltx_document'><p>\(prose)</p><table>\(rows)</table></article>"
    let blocks = try await HTMLPaperParser(transport: NoHTMLNetwork()).parse(Data(html.utf8), at: sourceURL)
    let pages = try await StructuredPageRenderer().render(
        blocks.map { BilingualBlock(block: $0, translation: nil) }, to: directory,
        originalURL: directory.appendingPathComponent("unused.pdf"))
    #expect(pages.count > 3)
    let text = try pages.map {
        try #require(PDFDocument(url: directory.appendingPathComponent($0.relativePath))?.string)
    }.joined(separator: " ")
    for index in 0..<180 { #expect(text.contains("Sentence\(index)")) }
    for index in 0..<60 {
        #expect(text.contains("Row\(index)"))
        #expect(text.contains("Value\(index)"))
    }
    #expect(pages.first?.blockIDs.contains(blocks[0].id) == true)
    #expect(pages.last?.blockIDs.contains(blocks[1].id) == true)
    _ = try PDFDisplayDocument.load(
        urls: pages.map { directory.appendingPathComponent($0.relativePath) }, expectedPageCount: pages.count)
}

private actor HTMLResponses: HTTPTransport {
    var requests: [URL] = []
    let html: String
    let responseURL: URL?
    init(html: String, responseURL: URL? = nil) {
        self.html = html
        self.responseURL = responseURL
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requests.append(url)
        return (
            Data(html.utf8),
            HTTPURLResponse(url: responseURL ?? url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func arxivHTMLRequiresExactVersionAndDoesNotFollowChangedResponseIdentity() async throws {
    let html = "<article class='ltx_document'><p>Original fixture content.</p></article>"
    let transport = HTMLResponses(html: html)
    let client = ArxivClient(transport: transport)
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Fixture", authors: "Test", year: "2024",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    #expect(try await client.structuredContent(candidate)?.count == 1)
    #expect(await transport.requests == [sourceURL])
    var unversioned = candidate
    unversioned.id = "https://arxiv.org/abs/2401.00001"
    unversioned.pdfURL = URL(string: "https://arxiv.org/pdf/2401.00001")!
    #expect(try await client.structuredContent(unversioned) == nil)
    #expect(await transport.requests.count == 1)
    let changed = ArxivClient(
        transport: HTMLResponses(html: html, responseURL: URL(string: "https://arxiv.org/html/2401.00001v2")!))
    #expect(try await changed.structuredContent(candidate) == nil)
    await #expect(throws: (any Error).self) {
        try await HTMLPaperParser().parse(
            Data(("<meta name='citation_arxiv_id' content='2401.00001v2'>" + html).utf8), at: sourceURL)
    }
}

@Test func unmappedHTMLKeepsBlockReferencesWithoutInventingOriginalPageNumbers() {
    let block = TextBlock(sourcePage: -1, text: "Unique evidence in a structured source.")
    var paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "original.pdf", pageCount: 3, blocks: [block], warnings: [],
        canReflow: true)
    paper.translatedBlockCount = 1
    paper.translatedPages = [PageArtifact(blockIDs: [block.id], sourcePage: -1, relativePath: "final.pdf")]
    let evidence = Retriever.context(question: "evidence", selection: "", current: paper, others: [], notes: [])
    #expect(evidence.first?.blockID == block.id)
    #expect(evidence.first?.sourcePage == nil)
    #expect(PaperPageLocator.position(sourcePage: -1, blockID: block.id, mode: "translated", in: paper) != nil)
    #expect(PaperPageLocator.position(sourcePage: -1, mode: "original", in: paper) == nil)
    #expect(PaperTextSearch.search("evidence", in: paper).first?.blockID == block.id)
}

private func pixels(of page: PDFPage) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    context.drawPDFPage(try #require(page.pageRef))
    return Data(bytes: try #require(context.data), count: 612 * 792 * 4)
}
