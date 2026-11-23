import Foundation
import Testing

@testable import PaperReaderKit

private let candidate = PaperCandidate(
    id: "https://arxiv.org/abs/2401.00001", title: "Catalog fixture", authors: "Reader", year: "2024",
    pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001")!)

private func abstractHTML(
    identifier: String = "2401.00001", permalink: String? = nil, current: String = ""
) -> String {
    """
    <html><head>
    <meta name="citation_arxiv_id" content="\(identifier)">
    <meta name="citation_title" content="Verified fixture title">
    \(permalink.map { #"<meta property="og:url" content="\#($0)">"# } ?? "")
    </head><body><div class="submission-history">
    <strong><a href="/abs/2401.00001v1">[v1]</a></strong> Previous submission.
    \(current)
    </div></body></html>
    """
}

@Test(arguments: [
    abstractHTML(permalink: "https://arxiv.org/abs/2401.00001v2"),
    abstractHTML(current: "<strong>[v2]</strong>"),
    abstractHTML(permalink: "https://arxiv.org/abs/2401.00001v2", current: "<strong>[v2]</strong>"),
])
func abstractPinsAnIdentifiedVersionOfTheRequestedPaper(html: String) throws {
    let pinned = try ArxivAbstractVersion.parse(html, candidate: candidate, identifier: "2401.00001")
    #expect(pinned.id == "https://arxiv.org/abs/2401.00001v2")
    #expect(pinned.pdfURL.absoluteString == "https://arxiv.org/pdf/2401.00001v2")
    #expect(pinned.title == "Verified fixture title")
}

@Test(arguments: [
    abstractHTML(), "<html><title>Rate limit</title></html>",
    abstractHTML(identifier: "2401.99999", current: "<strong>[v2]</strong>"),
    abstractHTML(permalink: "https://arxiv.org/abs/2401.99999v2", current: "<strong>[v2]</strong>"),
    abstractHTML(permalink: "https://example.org/abs/2401.00001v2", current: "<strong>[v2]</strong>"),
    abstractHTML(permalink: "https://arxiv.org/abs/2401.00001v2", current: "<strong>[v3]</strong>"),
])
func abstractRejectsMissingContradictoryOrForeignVersionEvidence(html: String) {
    #expect(throws: (any Error).self) {
        try ArxivAbstractVersion.parse(html, candidate: candidate, identifier: "2401.00001")
    }
}

private actor ThrottledPublicationTransport: HTTPTransport {
    private(set) var paths: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        paths.append(url.path)
        let status: Int
        let body: String
        switch url.path {
        case "/api/query":
            status = 429
            body = "Rate exceeded"
        case "/abs/2401.00001":
            status = 200
            body = abstractHTML(current: "<strong>[v2]</strong>")
        case "/src/2401.00001v2":
            status = 200
            body = #"\documentclass{article}\begin{document}Fixture\end{document}"#
        case "/pdf/2401.00001v2":
            status = 200
            body = "%PDF-1.7\nfixture"
        default: throw ReaderError.message("Unexpected path.")
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "300"])!
        )
    }
}

@Test func throttledVersionLookupStillImportsMatchingSourceAndPDF() async throws {
    let transport = ThrottledPublicationTransport()
    let client = ArxivClient(transport: transport)
    let downloaded = try await client.downloadPublication(candidate)
    defer { try? FileManager.default.removeItem(at: downloaded.pdfURL) }
    #expect(downloaded.candidate.id == "https://arxiv.org/abs/2401.00001v2")
    #expect(downloaded.texArchive != nil)
    #expect(await transport.paths == ["/api/query", "/abs/2401.00001", "/src/2401.00001v2", "/pdf/2401.00001v2"])
}
