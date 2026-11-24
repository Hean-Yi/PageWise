import Foundation
import Testing

@testable import PaperReaderKit

private actor DOITransport: HTTPTransport {
    let body: Data
    let status: Int
    let responseURL: URL?
    let headers: [String: String]
    private(set) var requests: [URLRequest] = []

    init(_ body: Data, status: Int = 200, responseURL: URL? = nil, headers: [String: String] = [:]) {
        self.body = body
        self.status = status
        self.responseURL = responseURL
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            body,
            HTTPURLResponse(
                url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }
}

private func doiRow(_ id: String, landing: String? = nil, version: String? = "2") -> [String: Any] {
    let doi = "10.48550/arXiv." + id
    var attributes: [String: Any] = [
        "doi": doi, "url": landing ?? "https://arxiv.org/abs/" + id,
        "titles": [["title": "Machine Reading \n With Evidence"]],
        "creators": [
            ["name": "Lee, Alex", "givenName": "Alex", "familyName": "Lee"], ["name": "Example Collaboration"],
        ],
        "publicationYear": 2026,
    ]
    if let version { attributes["version"] = version }
    return ["id": doi.lowercased(), "type": "dois", "attributes": attributes]
}

@Test func arxivDOISearchScopesTheRequestAndChecksVersionsAndIdentity() async throws {
    let rows = [
        doiRow("2601.00123"), doiRow("2601.00123"), doiRow("hep-th/0001234", version: nil),
        doiRow("2601.00222", landing: "http://arxiv.org/abs/2601.00222v3", version: nil),
        doiRow("2601.00333", landing: "https://arxiv.org/abs/2601.00222"),
        doiRow("2601.00444", landing: "https://arxiv.org/abs/2601.00444v1"),
        doiRow("2601.00555", landing: "https://elsewhere.example/abs/2601.00555"),
        doiRow("2601.00666", version: "+3"),
    ]
    let transport = DOITransport(try JSONSerialization.data(withJSONObject: ["data": rows]))
    let results = try await ArxivDOISearch.search("on-policy self-distillation", limit: 65, using: transport)
    let request = try #require(await transport.requests.first)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(components.scheme == "https" && components.host == "api.datacite.org" && components.path == "/dois")
    #expect(values["prefix"] == "10.48550" && values["page[size]"] == "40")
    #expect(values["query"] == #"titles.title:("on" AND "policy" AND "self" AND "distillation")"#)
    #expect(
        results.map(\.id) == [
            "https://arxiv.org/abs/2601.00123v2", "https://arxiv.org/abs/hep-th/0001234",
            "https://arxiv.org/abs/2601.00222v3",
        ])
    #expect(results.first?.title == "Machine Reading With Evidence")
    #expect(results.first?.authors == "Alex Lee, Example Collaboration")
    #expect(results.first?.year == "2026")
    #expect(results.first?.pdfURL?.absoluteString == "https://arxiv.org/pdf/2601.00123v2")
}

@Test func arxivDOISearchDistinguishesEmptyResultsAndUnusableResponses() async throws {
    let empty = Data(#"{"data":[]}"#.utf8)
    #expect(try await ArxivDOISearch.search("retrieval", limit: 3, using: DOITransport(empty)).isEmpty)
    var foreign = doiRow("2601.00444")
    foreign["id"] = "10.1000/arxiv.2601.00444"
    let unverified = try JSONSerialization.data(withJSONObject: ["data": [foreign]])
    for transport in [
        DOITransport(unverified), DOITransport(Data("invalid".utf8)),
        DOITransport(Data(repeating: 0, count: 2_000_001)),
        DOITransport(empty, status: 503),
        DOITransport(empty, responseURL: URL(string: "https://elsewhere.example/dois")),
    ] {
        await #expect(throws: ArxivDOISearch.Failure.self) {
            try await ArxivDOISearch.search("retrieval", limit: 3, using: transport)
        }
    }
}

@Test func arxivDOISearchPropagatesRegistryRateLimits() async throws {
    let transport = DOITransport(Data(), status: 429, headers: ["Retry-After": "300"])
    let start = Date()
    do {
        _ = try await ArxivDOISearch.search("retrieval", limit: 3, using: transport)
        Issue.record("Expected registry rate limit")
    } catch ArxivDOISearch.Failure.rateLimited(let until) {
        #expect(until >= start.addingTimeInterval(299))
    }
}
