import Foundation
import Testing

@testable import PaperReaderKit

private struct FeedTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.first?.value?.contains(" AND ") == true)
        let xml = """
            <feed xmlns="http://www.w3.org/2005/Atom"><entry>
            <id>http://arxiv.org/abs/0000.00000v1</id><title>Attention Is All You Need</title>
            <published>2020-01-01T00:00:00Z</published>
            <author><name>Example Author</name></author>
            <link href="http://arxiv.org/pdf/0000.00000v1" title="pdf" type="application/pdf" />
            </entry></feed>
            """
        return (
            Data(xml.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func partialTitleUsesTermsAndParsesVerifiedCandidate() async throws {
    let client = ArxivClient(transport: FeedTransport())
    let result = try await client.search("Attention all need")
    #expect(result.count == 1)
    #expect(result[0].authors == "Example Author")
    #expect(result[0].year == "2020")
    #expect(result[0].pdfURL.scheme == "https")
    #expect(result[0].pdfURL.host == "arxiv.org")
    #expect(ArxivClient.normalized(result[0].title) != ArxivClient.normalized("Attention all need"))
}

private actor DownloadTransport: HTTPTransport {
    var count = 0
    var target: URL?
    let redirect: Bool
    init(redirect: Bool = false) { self.redirect = redirect }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        target = request.url
        return (
            Data("%PDF-1.7\nfixture".utf8),
            HTTPURLResponse(
                url: redirect ? URL(string: "https://evil.invalid/paper.pdf")! : request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func arxivDownloadUsesInjectedTransportAndValidatesFinalOrigin() async throws {
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Fixture", authors: "A", year: "2024",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let transport = DownloadTransport()
    let discovery: any PaperDiscovery = ArxivClient(transport: transport)
    let url = try await discovery.download(candidate)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try Data(contentsOf: url).starts(with: Data("%PDF-".utf8)))
    #expect(await transport.count == 1)
    await #expect(throws: (any Error).self) {
        try await ArxivClient(transport: DownloadTransport(redirect: true)).download(candidate)
    }
}

@Test(arguments: [
    "https://user:password@arxiv.org/pdf/2401.00001v1", "https://evil.invalid/pdf/2401.00001v1",
    "https://arxiv.org:444/pdf/2401.00001v1", "https://arxiv.org/pdf/2401.00001v1?next=https://evil.invalid",
    "https://arxiv.org/pdf/2501.00002v1",
])
func arxivRejectsUntrustedCandidateWithoutNetworking(_ address: String) async throws {
    let transport = DownloadTransport()
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Fixture", authors: "A", year: "2024",
        pdfURL: URL(string: address)!)
    await #expect(throws: (any Error).self) { try await ArxivClient(transport: transport).download(candidate) }
    #expect(await transport.count == 0)
}
