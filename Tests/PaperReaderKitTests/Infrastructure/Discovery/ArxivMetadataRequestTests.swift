import Foundation
import Testing

@testable import PaperReaderKit

private actor MetadataTransport: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: String = "<feed/>")
        case network(URLError.Code)
    }
    private var replies: [Reply]
    private let latency: Duration
    private(set) var starts: [ContinuousClock.Instant] = []
    private var active = 0
    private(set) var peak = 0

    init(_ replies: [Reply], latency: Duration = .zero) {
        self.replies = replies
        self.latency = latency
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        starts.append(.now)
        active += 1
        peak = max(active, peak)
        defer { active -= 1 }
        guard !replies.isEmpty else { throw ReaderError.message("Unexpected metadata request") }
        let reply = replies.removeFirst()
        try await Task.sleep(for: latency)
        switch reply {
        case .network(let code): throw URLError(code)
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

/// Exercises the Atom queue independently of the DOI search index.
private struct AtomSearchFixture {
    let transport: any HTTPTransport
    let metadataRequests: ArxivMetadataRequests

    func search(_ query: String, limit: Int = 8) async throws -> [PaperCandidate] {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [.init(name: "search_query", value: query)]
        return try await metadataRequests.results(
            for: components.url!, using: transport, searchKey: query.lowercased(), limit: limit)
    }
}

@Test func arxivRetriesTemporaryHTTPAndNetworkFailuresWithinOneSearch() async throws {
    let transport = MetadataTransport([.http(503), .network(.timedOut), .http(200)])
    let client = AtomSearchFixture(transport: transport, metadataRequests: .init(spacing: .zero))
    #expect(try await client.search("memory").isEmpty)
    #expect(await transport.starts.count == 3)
}

@Test func arxivStopsAfterBoundedAttemptsAndReportsHTTPStatus() async throws {
    let transport = MetadataTransport(Array(repeating: .http(502), count: 3))
    let client = AtomSearchFixture(transport: transport, metadataRequests: .init(spacing: .zero))
    do {
        _ = try await client.search("memory")
        Issue.record("Expected arXiv service failure")
    } catch let error as ArxivQueryError {
        guard case .http(502, nil) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(!error.canRefineQuery)
    }
    #expect(await transport.starts.count == 3)
}

@Test func arxivHonorsLongServerCooldownAcrossClientsWithoutSendingAnotherRequest() async throws {
    let gate = ArxivMetadataRequests(spacing: .zero, maxAutomaticWait: 0.1)
    let transport = MetadataTransport([.http(429, headers: ["Retry-After": "300"])])
    var deadline: Date?
    for query in ["retrieval", "agent memory"] {
        let client = AtomSearchFixture(transport: transport, metadataRequests: gate)
        do {
            _ = try await client.search(query)
            Issue.record("Expected arXiv cooldown")
        } catch let error as ArxivQueryError {
            switch error {
            case .http(429, let until?) where deadline == nil:
                #expect(until > Date())
                deadline = until
            case .cooldown(429, let until):
                #expect(until == deadline)
            default: Issue.record("Unexpected arXiv error")
            }
            #expect(!error.canRefineQuery)
        }
    }
    #expect(await transport.starts.count == 1)
}

@Test func arxivUnderstandsSecondsAndHTTPDateRetryAfterHeaders() {
    let date = Date(timeIntervalSince1970: 1_445_412_480)
    #expect(ArxivMetadataRequests.retryDate("120", now: date) == date.addingTimeInterval(120))
    #expect(ArxivMetadataRequests.retryDate("Wed, 21 Oct 2015 07:28:00 GMT", now: date) == date)
    #expect(ArxivMetadataRequests.retryDate("invalid") == nil)
}

@Test func arxivUsesSingleConnectionAndSpacesRequestsAcrossClients() async throws {
    let spacing = Duration.milliseconds(45)
    let gate = ArxivMetadataRequests(spacing: spacing)
    let transport = MetadataTransport(Array(repeating: .http(200), count: 3), latency: .milliseconds(15))
    try await withThrowingTaskGroup(of: Void.self) { group in
        for query in ["memory", "attention", "planning"] {
            group.addTask {
                _ = try await AtomSearchFixture(transport: transport, metadataRequests: gate).search(query)
            }
        }
        try await group.waitForAll()
    }
    let starts = await transport.starts
    #expect(await transport.peak == 1)
    #expect(starts.count == 3)
    for (first, second) in zip(starts, starts.dropFirst()) {
        #expect(first.duration(to: second) >= spacing)
    }
}

@Test func arxivClassifiesPermanentFailuresAndInvalidPayloadsWithoutRetrying() async throws {
    let atomError = "<feed><entry><id>http://arxiv.org/api/errors#bad_query</id><title>Error</title></entry></feed>"
    for (reply, canRefine) in [
        (MetadataTransport.Reply.http(400), true), (.http(403), false), (.http(200, body: atomError), true),
        (.http(200, body: "<html><body>gateway</body></html>"), false), (.network(.notConnectedToInternet), false),
    ] {
        let transport = MetadataTransport([reply])
        let client = AtomSearchFixture(transport: transport, metadataRequests: .init(spacing: .zero))
        do {
            _ = try await client.search("memory")
            Issue.record("Expected classified arXiv error")
        } catch let error as ArxivQueryError {
            #expect(error.canRefineQuery == canRefine)
        }
        #expect(await transport.starts.count == 1)
    }
}

@Test func arxivCancellationDoesNotIssueARetryOrHoldTheQueue() async throws {
    let transport = MetadataTransport([.network(.cancelled), .http(200)])
    let client = AtomSearchFixture(transport: transport, metadataRequests: .init(spacing: .zero))
    await #expect(throws: CancellationError.self) { _ = try await client.search("memory") }
    #expect(try await client.search("attention").isEmpty)
    #expect(await transport.starts.count == 2)
}

@Test func arxivOnlyReportsEmptyWhenTheFeedHasNoMatches() throws {
    let opening =
        #"<atom:feed xmlns:atom="http://www.w3.org/2005/Atom" xmlns:os="http://a9.com/-/spec/opensearch/1.1/">"#
    let entry = """
        <atom:entry><atom:id>https://arxiv.org/abs/2401.00001v1</atom:id><atom:title>Matched paper</atom:title>
        <atom:link title="pdf" href="https://arxiv.org/pdf/2401.00001v1"/></atom:entry>
        """
    func feed(_ body: String) -> Data { Data((opening + body + "</atom:feed>").utf8) }
    #expect(try ArxivClient.parseMetadata(feed("<os:totalResults>0</os:totalResults>")).isEmpty)
    #expect(try ArxivClient.parseMetadata(feed(entry)).map(\.title) == ["Matched paper"])
    for body in [
        "<os:totalResults>3</os:totalResults>", "<atom:entry><atom:title>Broken record</atom:title></atom:entry>",
    ] {
        #expect(throws: ArxivQueryError.self) { try ArxivClient.parseMetadata(feed(body)) }
    }
}

@Test func arxivRejectsOversizedSearchBeforeContactingEitherService() async throws {
    let transport = MetadataTransport([])
    let client = ArxivClient(transport: transport)
    do {
        _ = try await client.search(String(repeating: "a", count: 4_097))
        Issue.record("Expected an invalid query")
    } catch ArxivQueryError.invalidQuery {}
    #expect(await transport.starts.isEmpty)
}

@Test func aHeaderless429DoesNotScheduleAnotherRequestOrExtendTheNextQueriesDeadline() async throws {
    let gate = ArxivMetadataRequests(spacing: .zero, throttleDelay: 120)
    let transport = MetadataTransport([.http(429)])
    let client = AtomSearchFixture(transport: transport, metadataRequests: gate)
    do {
        _ = try await client.search("OPSD")
        Issue.record("Expected HTTP 429")
        return
    } catch ArxivQueryError.http(429, nil) {}
    var deadlines: [Date] = []
    for term in ["on-policy self-distillation", "on-policy distillation"] {
        do {
            _ = try await client.search(term)
            Issue.record("Expected local cooldown")
        } catch ArxivQueryError.cooldown(429, let until) { deadlines.append(until) }
    }
    #expect(deadlines.count == 2 && deadlines[0] == deadlines[1] && deadlines[0] > Date())
    #expect(await transport.starts.count == 1)
}

@Test func arxivCachesVerifiedNonemptyResultsForConcurrentAndSmallerQueries() async throws {
    let feed = """
        <feed><entry><id>http://arxiv.org/abs/0000.00001v1</id><title>Attention</title>
        <link href="http://arxiv.org/pdf/0000.00001v1" type="application/pdf"/></entry>
        <entry><id>http://arxiv.org/abs/0000.00002v1</id><title>Memory</title>
        <link href="http://arxiv.org/pdf/0000.00002v1" title="pdf"/></entry></feed>
        """
    let transport = MetadataTransport([.http(200, body: feed), .http(200), .http(200)], latency: .milliseconds(5))
    let gate = ArxivMetadataRequests(spacing: .zero)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for query in ["Attention memory", "attention memory"] {
            group.addTask {
                let client = AtomSearchFixture(transport: transport, metadataRequests: gate)
                let results = try await client.search(query, limit: 8)
                #expect(results.count == 2)
            }
        }
        try await group.waitForAll()
    }
    let client = AtomSearchFixture(transport: transport, metadataRequests: gate)
    #expect(try await client.search("ATTENTION memory", limit: 1).map(\.title) == ["Attention"])
    #expect(await transport.starts.count == 1)
    #expect(try await client.search("attention memory", limit: 13).isEmpty)
    #expect(try await client.search("attention memory", limit: 13).isEmpty)
    #expect(await transport.starts.count == 3)
}

@Test func arxivCancelsWaitDuringBackoffBeforeAnotherRequestIsSent() async throws {
    let transport = MetadataTransport([.http(503)])
    let gate = ArxivMetadataRequests(spacing: .seconds(60))
    let client = AtomSearchFixture(transport: transport, metadataRequests: gate)
    let search = Task { try await client.search("attention") }
    while await transport.starts.isEmpty { await Task.yield() }
    search.cancel()
    await #expect(throws: CancellationError.self) { try await search.value }
    #expect(await transport.starts.count == 1)
}
