import Foundation
import Testing

@testable import PaperReaderKit

private actor SearchRoutingTransport: HTTPTransport {
    enum Reply: Sendable {
        case doiMatch, doiEmpty, atomMatch, atomEmpty, unavailable, throttled, cancelled
    }

    static let doiHost = "api.datacite.org"
    static let atomHost = "export.arxiv.org"

    private var replies: [Reply]
    private(set) var hosts: [String] = []
    private let pauseAtom: Bool
    private var atomDelay: Task<Void, Never>?
    var atomIsPending: Bool { atomDelay != nil }

    init(_ replies: [Reply], pauseAtom: Bool = false) {
        self.replies = replies
        self.pauseAtom = pauseAtom
    }

    func releaseAtom() { atomDelay?.cancel() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        hosts.append(try #require(url.host))
        let reply = try #require(replies.first)
        replies.removeFirst()
        if pauseAtom, url.host == Self.atomHost {
            // The timeout also lets a regressed single queue finish and report its failed assertion.
            let delay = Task<Void, Never> { try? await Task.sleep(for: .seconds(3)) }
            atomDelay = delay
            await delay.value
            atomDelay = nil
        }
        var status = 200
        var headers: [String: String] = [:]
        let body: String
        switch reply {
        case .doiMatch:
            body = """
                {"data":[{"id":"10.48550/arxiv.2601.00001","type":"dois","attributes":{
                "doi":"10.48550/arxiv.2601.00001","url":"https://arxiv.org/abs/2601.00001",
                "version":"2","titles":[{"title":"Windowed Ledger Indexes"}],
                "creators":[{"name":"Fixture Author"}],"publicationYear":2026}}]}
                """
        case .doiEmpty: body = #"{"data":[]}"#
        case .atomMatch:
            body = """
                <feed xmlns="http://www.w3.org/2005/Atom"><entry>
                <id>http://arxiv.org/abs/2601.00002v1</id><title>Paired Ledger Indexes</title>
                <link href="http://arxiv.org/pdf/2601.00002v1" title="pdf" type="application/pdf"/>
                </entry></feed>
                """
        case .atomEmpty: body = #"<feed xmlns="http://www.w3.org/2005/Atom"/>"#
        case .unavailable:
            status = 503
            body = ""
        case .throttled:
            status = 429
            headers["Retry-After"] = "600"
            body = "Rate exceeded."
        case .cancelled: throw URLError(.cancelled)
        }
        return (
            Data(body.utf8),
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        )
    }
}

@Test func coldArxivSearchCanReturnVerifiedCandidatesWithoutContactingTheExportAPI() async throws {
    let transport = SearchRoutingTransport([.doiMatch])
    let hits = try await ArxivClient(transport: transport).search("Windowed Ledger", limit: 1)
    #expect(hits.map(\.id) == ["https://arxiv.org/abs/2601.00001v2"])
    #expect(hits.first?.pdfURL.absoluteString == "https://arxiv.org/pdf/2601.00001v2")
    #expect(hits.first?.indexedByDataCite == true)
    #expect(await transport.hosts == [SearchRoutingTransport.doiHost])
}

@Test func coldArxivSearchCanFinishAnotherDOIQueryWhileAtomIsPending() async throws {
    let transport = SearchRoutingTransport([.doiEmpty, .atomMatch, .doiMatch], pauseAtom: true)
    let client = ArxivClient(transport: transport)
    async let slow = client.search("Paired Ledger")
    let deadline = ContinuousClock.now + .seconds(3)
    while await !transport.atomIsPending, ContinuousClock.now < deadline { await Task.yield() }
    try #require(await transport.atomIsPending)
    async let duplicate = client.search("Paired Ledger")

    let fast = try await client.search("Windowed Ledger")
    #expect(fast.map(\.title) == ["Windowed Ledger Indexes"])
    #expect(await transport.atomIsPending)
    await transport.releaseAtom()
    let (first, second) = try await (slow, duplicate)
    #expect(first.map(\.title) == ["Paired Ledger Indexes"])
    #expect(second.map(\.id) == first.map(\.id))
    let doi = SearchRoutingTransport.doiHost
    #expect(await transport.hosts == [doi, SearchRoutingTransport.atomHost, doi])
}

@Test(arguments: [SearchRoutingTransport.Reply.doiEmpty, .unavailable])
private func coldArxivSearchChecksTheOfficialFeedWhenTheDOIIndexHasNoUsableAnswer(
    firstReply: SearchRoutingTransport.Reply
) async throws {
    let transport = SearchRoutingTransport([firstReply, .atomMatch])
    let hits = try await ArxivClient(transport: transport).search("Paired Ledger")
    #expect(hits.map(\.id) == ["https://arxiv.org/abs/2601.00002v1"])
    #expect(await transport.hosts == [SearchRoutingTransport.doiHost, SearchRoutingTransport.atomHost])
}

@Test func coldArxivSearchReturnsZeroWhenTheOfficialFeedConfirmsNoMatches() async throws {
    let transport = SearchRoutingTransport([.doiEmpty, .atomEmpty])
    #expect(try await ArxivClient(transport: transport).search("Absent Fixture").isEmpty)
    #expect(await transport.hosts == [SearchRoutingTransport.doiHost, SearchRoutingTransport.atomHost])
}

@Test(arguments: [SearchRoutingTransport.Reply.doiEmpty, .unavailable])
private func coldArxivSearchReportsIncompleteCoverageAndKeepsSearchingDOIsDuringExportCooldown(
    firstReply: SearchRoutingTransport.Reply
) async throws {
    let transport = SearchRoutingTransport([firstReply, .throttled, .doiEmpty, .doiMatch])
    let client = ArxivClient(transport: transport)
    var firstDeadline: Date?
    for (term, expectedEmptyDOI) in [("First Fixture", firstReply == .doiEmpty), ("Second Fixture", true)] {
        do {
            _ = try await client.search(term)
            Issue.record("Expected an incomplete search")
        } catch ArxivQueryError.incompleteSearch(let arxiv, let doiReturnedNoMatches) {
            #expect(doiReturnedNoMatches == expectedEmptyDOI)
            switch arxiv {
            case .http(429, let until?) where firstDeadline == nil: firstDeadline = until
            case .cooldown(429, let until): #expect(until == firstDeadline)
            default: Issue.record("Expected the live 429 followed by its shared cooldown")
            }
        }
    }
    let results = try await client.search("Windowed Ledger")
    #expect(results.map(\.title) == ["Windowed Ledger Indexes"])
    let doi = SearchRoutingTransport.doiHost
    #expect(await transport.hosts == [doi, SearchRoutingTransport.atomHost, doi, doi])
}

@Test(arguments: [false, true])
func coldArxivSearchPropagatesCancellationAtEitherIndex(cancelAtom: Bool) async throws {
    let transport = SearchRoutingTransport(cancelAtom ? [.doiEmpty, .cancelled] : [.cancelled])
    await #expect(throws: CancellationError.self) {
        _ = try await ArxivClient(transport: transport).search("Cancelled Fixture")
    }
    let doi = SearchRoutingTransport.doiHost
    #expect(await transport.hosts == (cancelAtom ? [doi, SearchRoutingTransport.atomHost] : [doi]))
}
