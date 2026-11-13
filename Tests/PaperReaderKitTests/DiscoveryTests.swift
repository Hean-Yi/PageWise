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
