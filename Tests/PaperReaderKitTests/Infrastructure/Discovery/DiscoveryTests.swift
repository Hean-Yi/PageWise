import Foundation
import Testing

@testable import PaperReaderKit

private struct FeedTransport: HTTPTransport {
    var expectedLimit = 8
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let url = request.url, url.host == "api.datacite.org" {
            return (
                Data(#"{"data":[]}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.first?.value?.contains(" AND ") == true)
        #expect(components?.queryItems?.first { $0.name == "max_results" }?.value == String(expectedLimit))
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

@Test func arxivAcceptsTheAgentSearchBudgetThroughTheDiscoveryProtocol() async throws {
    let client: any PaperDiscovery = ArxivClient(transport: FeedTransport(expectedLimit: 13))
    let results = try await client.search("attention memory", limit: 13)
    #expect(results.count == 1)
}

@Test func partialTitleUsesTermsAndParsesVerifiedCandidate() async throws {
    let client = ArxivClient(transport: FeedTransport())
    let result = try await client.search("Attention all need")
    #expect(result.count == 1)
    #expect(result[0].authors == "Example Author")
    #expect(result[0].year == "2020")
    #expect(result[0].pdfURL?.scheme == "https")
    #expect(result[0].pdfURL?.host == "arxiv.org")
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

private actor PublicationTransport: HTTPTransport {
    var paths: [String] = []
    var files: [URL] = []
    var limits: [Int64] = []
    let sourceAvailable: Bool
    let wrongVersion: Bool
    init(sourceAvailable: Bool = true, wrongVersion: Bool = false) {
        self.sourceAvailable = sourceAvailable
        self.wrongVersion = wrongVersion
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.path == "/api/query")
        return response(for: request)
    }
    func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let (bytes, http) = response(for: request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        files.append(file)
        limits.append(maximumBytes)
        return (file, http)
    }
    private func response(for request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        let source = url.path.hasPrefix("/src/")
        let body: String
        if url.path == "/api/query" {
            body = """
                <feed><entry><id>https://arxiv.org/abs/2401.00001v2</id><title>Original fixture</title>
                <link title="pdf" href="https://arxiv.org/pdf/2401.00001v2"/></entry></feed>
                """
        } else if source {
            body = #"\documentclass{article}\begin{document}Original source.\end{document}"#
        } else {
            body = "%PDF-1.7\nfixture"
        }
        let responseURL = source && wrongVersion ? URL(string: "https://arxiv.org/src/2401.00001v1")! : url
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: responseURL,
                statusCode: source && !sourceAvailable ? 404 : 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func onlineDownloadPinsVersionAndRequestsTeXBeforePDF() async throws {
    let transport = PublicationTransport()
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001", title: "Original", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001")!)
    let downloaded = try await ArxivClient(transport: transport).downloadPublication(candidate)
    defer { try? FileManager.default.removeItem(at: downloaded.pdfURL) }
    #expect(downloaded.candidate.id == "https://arxiv.org/abs/2401.00001v2")
    #expect(downloaded.texArchive != nil)
    #expect(downloaded.sourceNotice == nil)
    #expect(await transport.limits == [50_000_000, 50_000_000])
    #expect(await transport.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(String(decoding: downloaded.texArchive ?? Data(), as: UTF8.self).contains("Original source"))
    #expect(try Data(contentsOf: downloaded.pdfURL).starts(with: Data("%PDF-".utf8)))
    #expect(await transport.paths == ["/api/query", "/src/2401.00001v2", "/pdf/2401.00001v2"])
}

@Test(arguments: [false, true]) func missingOrMismatchedTeXStillDownloadsSameVersionPDF(wrongVersion: Bool) async throws
{
    let transport = PublicationTransport(sourceAvailable: wrongVersion, wrongVersion: wrongVersion)
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v2", title: "Original", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v2")!)
    let downloaded = try await ArxivClient(transport: transport).downloadPublication(candidate)
    defer { try? FileManager.default.removeItem(at: downloaded.pdfURL) }
    #expect(downloaded.texArchive == nil)
    #expect(downloaded.sourceNotice != nil)
    #expect(await transport.paths == ["/src/2401.00001v2", "/pdf/2401.00001v2"])
}

private final class UnfinishedDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "application/octet-stream"]
        if url.path == "/declared" { headers["Content-Length"] = "50000000" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/stream" {
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 3_000))
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 3_000))
        } else {
            // CFNetwork may buffer initial bytes before forwarding custom protocol response headers.
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 4_096))
        }
        // Deliberately never send a completion. Only early header/chunk checks can reject this file.
    }
    override func stopLoading() {}
}

@Test(arguments: ["/declared", "/stream"]) func networkTransportStopsAnOversizedResponseBeforeEOF(path: String)
    async throws
{
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UnfinishedDownloadProtocol.self]
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 3
    let transport = NetworkTransport(configuration: config)
    do {
        let (file, _) = try await transport.downloadFile(
            for: URLRequest(url: URL(string: "https://fixture.invalid" + path)!), maximumBytes: 4_096)
        try? FileManager.default.removeItem(at: file)
        Issue.record("Oversized download was accepted")
    } catch let error as ReaderError {
        #expect(error.localizedDescription == "全文超出下载大小限制。")
    }
}
