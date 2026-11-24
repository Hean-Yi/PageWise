import Foundation
import Testing

@testable import PaperReaderKit

private actor IndexFixture: HTTPTransport {
    struct Reply: Sendable {
        let body: String
        var status = 200
        var headers: [String: String] = [:]
    }

    private let response: @Sendable (URL) -> Reply
    private(set) var requests: [URLRequest] = []

    init(_ response: @escaping @Sendable (URL) -> Reply) { self.response = response }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requests.append(request)
        let reply = response(url)
        return (
            Data(reply.body.utf8),
            try #require(
                HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers))
        )
    }
}

@Test func crossrefUsesExactDOIAndKeepsBibliographySeparateFromFullText() async throws {
    let transport = IndexFixture { _ in
        .init(
            body: """
                {"message":{"items":[
                    {"DOI":"10.1000/Reader","title":[" Reading  metadata "],"issued":{"date-parts":[[2025,2]]},
                     "author":[{"given":"Kay","family":"Chan"},{"name":"Example Group"}],
                     "abstract":"<jats:p>Evidence from <jats:italic>two</jats:italic> settings.</jats:p>",
                     "relation":{"has-preprint":[{"id":"10.48550/arXiv.2501.12345"}]},
                     "link":[{"URL":"https://example.org/reader.pdf","content-type":"application/pdf"}]},
                    {"DOI":"10.1000/other","title":["Different record"]}]}}
                """)
    }
    let indexes = ScholarlyIndexes(transport: transport)
    async let first = indexes.crossref("https://doi.org/10.1000/Reader", limit: 70)
    async let second = indexes.crossref("doi:10.1000/reader", limit: 70)
    let batches = try await (first, second)
    #expect(batches.0.map(\.id) == batches.1.map(\.id))
    #expect(batches.0.count == 1)
    let paper = try #require(batches.0.first)
    #expect(paper.source == .crossref && paper.id == "https://doi.org/10.1000/reader" && paper.doi == "10.1000/reader")
    #expect(paper.title == "Reading metadata" && paper.authors == "Kay Chan, Example Group" && paper.year == "2025")
    #expect(paper.abstractText == "Evidence from two settings.")
    #expect(paper.relatedArxivID == "2501.12345" && !paper.canDownload)
    let requests = await transport.requests
    #expect(requests.count == 1)
    let url = try #require(requests.first?.url)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "rows", value: "40")))
    #expect(items.contains(URLQueryItem(name: "filter", value: "doi:10.1000/reader")))
    #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func dblpReadsSingleAndMultipleAuthorsWithAndWithoutDOI() async throws {
    let transport = IndexFixture { _ in
        .init(
            body: """
                {"result":{"hits":{"@total":"3","hit":[
                    {"info":{"title":"Conference note","key":"conf/test/Chan25","doi":"10.1000/reader","year":"2025",
                             "authors":{"author":{"@pid":"00/01","text":"Kay Chan"}}}},
                    {"info":{"title":"Preprint note","key":"journals/corr/abs-2501-12345","year":"2025",
                             "ee":"https://arxiv.org/abs/2501.12345","authors":{"author":["Kay Chan",{"text":"Bo Li"}]}}},
                    {"info":{"title":"Bad record","key":"../example"}}]}}}
                """)
    }
    let results = try await ScholarlyIndexes(transport: transport).dblp("reading", limit: 4)
    #expect(
        results.map(\.id) == ["https://doi.org/10.1000/reader", "https://dblp.org/rec/journals/corr/abs-2501-12345"])
    #expect(results.map(\.authors) == ["Kay Chan", "Kay Chan, Bo Li"])
    #expect(results.last?.relatedArxivID == "2501.12345")
}

@Test func blockedProvidersRespectTheirOwnCooldownAndPreserveOtherSearchResults() async throws {
    let transport = IndexFixture { url in
        switch url.host {
        case "api.semanticscholar.org": .init(body: "", status: 429, headers: ["Retry-After": "240"])
        case "dblp.org":
            .init(body: "<html>browser verification</html>", status: 202, headers: ["Content-Type": "text/html"])
        default: .init(body: #"{"message":{"items":[]}}"#)
        }
    }
    let indexes = ScholarlyIndexes(transport: transport)
    for _ in 1...2 {
        do {
            _ = try await indexes.related(to: "ARXIV:2501.12345", limit: 3)
            Issue.record("Expected rate limit")
        } catch ScholarlyIndexes.Failure.rateLimited(let source, let until) {
            #expect(source == .semanticScholar && until.timeIntervalSinceNow > 230)
        }
        do {
            _ = try await indexes.dblp("reading", limit: 3)
            Issue.record("Expected browser challenge")
        } catch ScholarlyIndexes.Failure.browserVerification {}
    }
    #expect(try await indexes.crossref("reading", limit: 3).isEmpty)
    #expect(await transport.requests.count == 3)
}

@Test func scholarRecommendationsUseVerifiedSeedAndExplicitPreprintRelation() async throws {
    let transport = IndexFixture { _ in
        .init(
            body: """
                {"recommendedPapers":[{"paperId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Grounded notes",
                  "externalIds":{"DOI":"10.1000/notes","ArXiv":"2501.12345","CorpusId":123},
                  "year":2025,"authors":[{"name":"Kay Chan"}],"openAccessPdf":{"url":"https://unrelated.example/file.pdf"}}]}
                """)
    }
    let indexes = ScholarlyIndexes(transport: transport)
    let results = try await indexes.related(to: "https://arxiv.org/abs/2401.01234v2", limit: 3)
    #expect(results.first?.source == .semanticScholar && results.first?.id == "https://doi.org/10.1000/notes")
    #expect(results.first?.relatedArxivID == "2501.12345" && results.first?.canDownload == false)
    let url = try #require(await transport.requests.first?.url)
    #expect(url.path == "/recommendations/v1/papers/forpaper/ARXIV:2401.01234")
    #expect(ScholarlyIndexes.recommendationID("https://fake.example/abs/2401.01234") == nil)
    _ = try await indexes.related(to: "DOI:10.1000/Exact", limit: 1)
    let doiURL = try #require(await transport.requests.last?.url)
    #expect(doiURL.absoluteString.contains("DOI:10.1000%2Fexact"))
}

@Test func scholarTitleSeedRejectsAmbiguousMatchesBeforeMakingRecommendations() async throws {
    let transport = IndexFixture { _ in
        .init(
            body: """
                {"data":[{"paperId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Sample Title"},
                         {"paperId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"Sample: Title"}]}
                """)
    }
    let indexes = ScholarlyIndexes(transport: transport)
    do {
        _ = try await indexes.relatedByTitle("Sample Title", limit: 5)
        Issue.record("Expected ambiguous title")
    } catch ScholarlyIndexes.Failure.ambiguousTitle {}
    #expect(await transport.requests.count == 1)
}

@Test func scholarTitleSeedRequestsOneIdentityMatchedToTheLocalTitle() async throws {
    let transport = IndexFixture { url in
        if url.path == "/graph/v1/paper/search" {
            .init(
                body: """
                    {"data":[{"paperId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Another title"},
                             {"paperId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"Sample: Title"}]}
                    """)
        } else {
            .init(body: #"{"recommendedPapers":[]}"#)
        }
    }
    let result = try await ScholarlyIndexes(transport: transport).relatedByTitle("Sample Title", limit: 2)
    #expect(result.isEmpty)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.last?.url?.lastPathComponent == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
}

@Test func crossrefDownloadRequiresAnEffectiveVersionOfRecordLicenseAndMatchingPublisherPDF() async throws {
    let transport = IndexFixture { _ in
        let papers = [
            ("allowed", "vor", 0, "vor", "creativecommons.org"),
            ("accepted-only", "am", 0, "vor", "creativecommons.org"),
            ("embargo", "vor", 4_102_444_800_000, "vor", "creativecommons.org"),
            ("wrong-file-version", "vor", 0, "am", "creativecommons.org"),
            ("publisher-terms", "vor", 0, "vor", "terms.example"),
        ]
        let rows = papers.map { name, licenseVersion, time, fileVersion, host in
            let doi = "10.1371/journal.pone." + name
            return """
                {"DOI":"\(doi)","title":["\(name)"],
                 "license":[{"content-version":"\(licenseVersion)","URL":"https://\(host)/licenses/by/4.0/",
                             "start":{"timestamp":\(time)}}],
                 "link":[{"URL":"https://journals.plos.org/plosone/article/file?id=\(doi)&type=printable",
                          "content-type":"application/pdf","content-version":"\(fileVersion)"}]}
                """
        }
        return .init(body: "{\"message\":{\"items\":[" + rows.joined(separator: ",") + "]}}")
    }
    let results = try await ScholarlyIndexes(transport: transport).crossref("sample", limit: 8)
    #expect(results.filter(\.canDownload).map(\.title) == ["allowed"])
    #expect(results.count == 5)
}
