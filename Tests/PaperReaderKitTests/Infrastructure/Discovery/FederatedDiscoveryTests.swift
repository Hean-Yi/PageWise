import Foundation
import Testing

@testable import PaperReaderKit

private func preprint(_ suffix: String = "v2", title: String = "Localized learning") -> PaperCandidate {
    let id = "2501.12345" + suffix
    return .init(
        id: "https://arxiv.org/abs/" + id, title: title, authors: "A", year: "2025",
        pdfURL: URL(string: "https://arxiv.org/pdf/" + id))
}

private func publication(_ doi: String, source: PaperSearchSource = .crossref, preprint: String? = nil)
    -> PaperCandidate
{
    .init(
        id: "https://doi.org/" + doi, title: "Localized learning", authors: "A", year: "2025",
        source: source, doi: doi, relatedArxivID: preprint)
}

@Test func mergeUsesIdentifiersAndKeepsEditionActions() throws {
    let pub = publication("10.1234/EXAMPLE", preprint: "2501.12345")
    let alsoIndexed = publication("10.1234/example", source: .dblp)
    let otherWork = publication("10.5678/different")
    let cards = PaperDiscoveryRanking.merge([[preprint()], [pub, otherWork], [alsoIndexed]], query: nil, limit: 8)
    #expect(cards.count == 2)
    #expect(cards[0].canDownload)
    #expect(cards[0].id == preprint().id)
    #expect(cards[0].alternateVersions.map(\.id) == [pub.id])
    #expect(!cards[0].alternateVersions[0].canDownload)
    #expect(cards[1].id == otherWork.id)
}

@Test func publisherDOIOnThePreprintCanLinkDistinctTitles() throws {
    let xml = """
        <feed xmlns:arxiv="http://arxiv.org/schemas/atom"><entry><id>https://arxiv.org/abs/2501.12345v1</id>
        <title>Earlier title</title><arxiv:doi>10.1234/EXAMPLE</arxiv:doi>
        <link title="pdf" href="https://arxiv.org/pdf/2501.12345v1"/></entry></feed>
        """
    let found = try ArxivClient.parseMetadata(Data(xml.utf8))
    let pub = publication("10.1234/example")
    let cards = PaperDiscoveryRanking.merge([found, [pub]], query: nil, limit: 4)
    #expect(cards.count == 1)
    #expect(cards.first?.alternateVersions.map(\.id) == [pub.id])
}

@Test func explicitPreprintRelationOffersASeparateVerifiedDownload() throws {
    let pub = publication("10.1234/example", preprint: "2501.12345")
    let cards = PaperDiscoveryRanking.merge([[pub]], query: nil, limit: 4)
    let result = try #require(cards.first)
    #expect(result.id == preprint("").id)
    #expect(result.canDownload)
    #expect(result.alternateVersions.map(\.id) == [pub.id])
}

@Test func matchingTitleAloneNeverMergesAndAnExactTitleSurvivesTheLimit() throws {
    let approximate = preprint(title: "Other title")
    let sameTitle = publication("10.1234/other")
    let cards = PaperDiscoveryRanking.merge([[approximate], [sameTitle]], query: sameTitle.title, limit: 1)
    #expect(cards.map(\.id) == [sameTitle.id])
    #expect(cards[0].alternateVersions.isEmpty)
    let distinct = PaperDiscoveryRanking.merge([[preprint()], [sameTitle]], query: nil, limit: 8)
    #expect(distinct.count == 2)
}

@Test func metadataOnlyCandidatesRequireATrustedPublicationPage() {
    let good = publication("10.1234/example")
    #expect(good.landingURL?.host == "doi.org")
    #expect(!good.canDownload)
    for invalid in [
        "http://doi.org/10.1234/example", "https://evil.example/10.1234/example",
        "https://user@doi.org/10.1234/example", "https://doi.org/10.1234/other",
    ] {
        var changed = good
        changed.id = invalid
        #expect(changed.verified == nil)
    }
}

private actor FixedPreprints: PaperDiscovery {
    let fail: Bool
    var calls = 0
    init(fail: Bool = false) { self.fail = fail }
    func search(_ query: String) async throws -> [PaperCandidate] {
        calls += 1
        if fail { throw ArxivQueryError.http(status: 429, retryAfter: nil) }
        return [preprint()]
    }
    func download(_ candidate: PaperCandidate) async throws -> URL { throw CancellationError() }
}

private actor IndexTransport: HTTPTransport {
    var hosts: [String] = []
    let empty: Bool
    let fail: Bool
    init(empty: Bool = false, fail: Bool = false) {
        self.empty = empty
        self.fail = fail
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let host = try #require(url.host)
        hosts.append(host)
        if host == "dblp.org" || fail { throw URLError(.timedOut) }
        #expect(host == "api.crossref.org")
        let item =
            #"{"DOI":"10.1234/example","type":"journal-article","title":["Other paper"],"issued":{"date-parts":[[2025]]}}"#
        let body = #"{"status":"ok","message-type":"work-list","message":{"items":["# + (empty ? "" : item) + "]}}"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func federatedSearchSurvivesIndependentFailuresAndScopesRequests() async throws {
    let transport = IndexTransport()
    let arxiv = FixedPreprints(fail: true)
    let service = FederatedPaperDiscovery(arxiv: arxiv, transport: transport)
    let onlyArxiv = try? await service.discover("test", scope: .arxiv, limit: 6)
    #expect(onlyArxiv == nil)
    #expect(await transport.hosts.isEmpty)
    let result = try await service.discover("test", scope: .all, limit: 6)
    #expect(result.candidates.contains { $0.doi == "10.1234/example" })
    #expect(result.notice?.contains("arXiv") == true)
    #expect(result.notice?.contains("DBLP") == true)
    #expect(await arxiv.calls == 2)
}

@Test func zeroResultsPartialSearchAndOutageAreDistinguishable() async throws {
    let empty = FederatedPaperDiscovery(arxiv: FixedPreprints(fail: true), transport: IndexTransport(empty: true))
    let complete = try await empty.discover("absent", scope: .crossref, limit: 2)
    #expect(complete.candidates.isEmpty && complete.notice == nil)
    let partial = try await empty.discover("absent", scope: .all, limit: 2)
    #expect(partial.candidates.isEmpty && partial.notice != nil)
    let failed = FederatedPaperDiscovery(arxiv: FixedPreprints(fail: true), transport: IndexTransport(fail: true))
    await #expect(throws: FederatedSearchError.self) { try await failed.discover("absent", scope: .all, limit: 2) }
}
