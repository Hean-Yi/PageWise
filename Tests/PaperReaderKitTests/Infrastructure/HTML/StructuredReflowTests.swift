import Foundation
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
        "<canvas>lost drawing</canvas>",
        "<p class='ltx_ERROR'>lost equation</p>",
    ] {
        await #expect(throws: (any Error).self) {
            try await parser.parse(Data("<article class='ltx_document'>\(content)</article>".utf8), at: sourceURL)
        }
    }
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
    try ReadingArtifactCleanup.removeUncommittedFiles(in: root, papers: [paper])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [keep, "user.pdf"])
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

@Test(arguments: [true, false]) func frontMatterSemanticsStayOutOfTranslationWithoutRemovingBody(tagged: Bool)
    async throws
{
    let authors = tagged ? "class='ltx_authors'" : ""
    let metadata = tagged ? "class='ltx_note ltx_role_correspondence'" : ""
    let html = """
        <article class='ltx_document'><h1>Original metadata fixture</h1>
        <div \(authors)><span class='ltx_personname'>Alex Researcher</span></div>
        <div class='ltx_abstract'><h2>Abstract</h2><p>Dates in experimental evidence remain ordinary prose.</p></div>
        <span \(metadata)><sup class='ltx_note_mark'>†</sup><span>correspondence: </span><a href='mailto:alex@example.org'>alex@example.org</a></span>
        <p>Date: </p><p>August 24, 2026</p>
        <section><h2>Introduction</h2><p>Date: the time of measurement affects the outcome.</p>
        <p>Contact: alex@example.org is an example in our dataset.</p>
        <p class='ltx_note'>This footnote explains the method and must remain.</p></section></article>
        """
    let blocks = try await HTMLPaperParser(transport: NoHTMLNetwork()).parse(Data(html.utf8), at: sourceURL)
    let metadataBlocks = blocks.filter { $0.richContent?.html.contains("<details>") == true }
    let front = try #require(metadataBlocks.first)
    #expect(metadataBlocks.count == 1)
    #expect(front.richContent?.requiresTranslation == false)
    #expect(front.text.contains("alex@example.org"))
    #expect(front.text.contains("August 24, 2026"))
    #expect(!front.text.contains("†"))
    let translated = blocks.filter { $0.richContent?.requiresTranslation == true }.map(\.text).joined(separator: "\n")
    #expect(!translated.contains("August 24, 2026"))
    #expect(translated.contains("Dates in experimental evidence"))
    #expect(translated.contains("Date: the time of measurement"))
    #expect(translated.contains("Contact: alex@example.org is an example"))
    #expect(translated.contains("This footnote explains the method"))
}

@Test func frontMatterConversionErrorsDoNotRejectVerifiedBody() async throws {
    let html = #"""
        <article class='ltx_document'>
        <div><p>1] Example University <span class='ltx_ERROR'>\customPublisherMetadata</span></p></div>
        <h1><span class='ltx_ERROR'>\titlefont</span>Original fixture</h1>
        <div class='ltx_authors'><span class='ltx_personname'>Alex</span><span class='ltx_ERROR'>\anotherAuthorMacro</span><img src='unavailable-logo.png'></div>
        <div class='ltx_abstract'><p>Real abstract remains readable.</p></div>
        <section><h2>Method</h2><p>Real body remains readable.</p>
        <div><span class='ltx_ERROR'>\nobibliography</span><p>*</p></div></section>
        <section class='ltx_bibliography'><ul class='ltx_biblist'><li>Original citation.</li></ul></section>
        <div><span class='ltx_ERROR'>\beginappendix</span></div>
        <section><h2>Additional results</h2><p>Appendix body stays present.</p></section>
        </article>
        """#
    let parser = HTMLPaperParser(transport: NoHTMLNetwork())
    let blocks = try await parser.parse(Data(html.utf8), at: sourceURL)
    let front = try #require(blocks.first { $0.richContent?.html.contains("<details>") == true })
    #expect(front.text.contains("Example University"))
    #expect(front.text.contains("customPublisherMetadata"))
    #expect(front.richContent?.requiresTranslation == false)
    #expect(blocks.allSatisfy { $0.hasImageFailure != true })
    let body = blocks.filter { $0.richContent?.requiresTranslation == true }.map(\.text).joined()
    #expect(body.contains("Real abstract remains readable"))
    #expect(body.contains("Real body remains readable"))
    #expect(body.contains("Appendix body stays present"))
    #expect(!body.contains("nobibliography"))
    #expect(!body.contains("customPublisherMetadata"))
    await #expect(throws: (any Error).self) {
        try await parser.parse(
            Data(
                html.replacingOccurrences(
                    of: "Real body remains readable.", with: #"<span class='ltx_ERROR'>\unknownBodyMacro</span>"#
                ).utf8), at: sourceURL)
    }
}
