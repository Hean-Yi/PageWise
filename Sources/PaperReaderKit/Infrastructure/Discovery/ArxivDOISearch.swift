import Foundation

/// Searches DOI metadata deposited by arXiv and cross-checks each DOI against its arXiv landing URL.
enum ArxivDOISearch {
    enum Failure: LocalizedError {
        case unavailable
        case rateLimited(until: Date)

        var errorDescription: String? {
            switch self {
            case .unavailable: "DataCite 的 arXiv 元数据暂时不可用。"
            case .rateLimited: "DataCite 暂时限制了检索频率。"
            }
        }
    }

    static func search(_ query: String, limit: Int, using transport: any HTTPTransport) async throws -> [PaperCandidate]
    {
        try Task.checkCancellation()
        let limit = min(40, limit)
        let words = query.split { !$0.isLetter && !$0.isNumber }.prefix(16)
        guard limit > 0, !words.isEmpty else { return [] }
        let terms = words.map { "\"\($0)\"" }.joined(separator: " AND ")
        var components = URLComponents(string: "https://api.datacite.org/dois")!
        components.queryItems = [
            .init(name: "prefix", value: "10.48550"),
            .init(name: "query", value: "titles.title:(\(terms))"),
            .init(name: "sort", value: "relevance"),
            .init(name: "page[size]", value: String(limit)),
            .init(name: "disable-facets", value: "true"),
            .init(name: "fields[dois]", value: "doi,titles,creators,publicationYear,url,version,relatedIdentifiers"),
        ]
        guard let url = components.url else { throw ArxivQueryError.invalidQuery }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        guard response.url == url else { throw Failure.unavailable }
        if response.statusCode == 429 {
            let until = ArxivMetadataRequests.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
            throw Failure.rateLimited(until: until ?? Date().addingTimeInterval(60))
        }
        guard response.statusCode == 200, data.count <= 2_000_000,
            let page = try? JSONDecoder().decode(Page.self, from: data)
        else { throw Failure.unavailable }
        var seen = Set<String>()
        let candidates = page.data.compactMap(\.candidate).filter { seen.insert($0.id).inserted }
        guard page.data.isEmpty || !candidates.isEmpty else { throw Failure.unavailable }
        return Array(candidates.prefix(limit))
    }

    private struct Page: Decodable {
        let data: [Record]
    }

    private struct Record: Decodable {
        struct Attributes: Decodable {
            struct Title: Decodable {
                let title: String
                let titleType: String?
            }
            struct RelatedIdentifier: Decodable {
                let relatedIdentifier: String?
                let relatedIdentifierType: String?
                let relationType: String?
            }
            let relatedIdentifiers: [RelatedIdentifier]?
            struct Creator: Decodable {
                let name: String
                let givenName: String?
                let familyName: String?

                var displayName: String {
                    if let givenName, let familyName, !givenName.isEmpty, !familyName.isEmpty {
                        return givenName + " " + familyName
                    }
                    return name
                }
            }
            let doi: String?
            let url: String?
            let version: String?
            let titles: [Title]?
            let creators: [Creator]?
            let publicationYear: Int?
        }

        let id: String
        let type: String
        let attributes: Attributes

        var candidate: PaperCandidate? {
            let prefix = "10.48550/arxiv."
            let doi = id.lowercased()
            guard type == "dois", doi.hasPrefix(prefix), attributes.doi?.lowercased() == doi,
                let landing = attributes.url.flatMap(URL.init(string:)),
                ["https", "http"].contains(landing.scheme), landing.host == "arxiv.org",
                landing.user == nil, landing.password == nil, landing.port == nil,
                landing.query == nil, landing.fragment == nil, landing.path.hasPrefix("/abs/"),
                let title = attributes.titles?.first(where: { $0.titleType == nil })?.title,
                let year = attributes.publicationYear, (1000...9999).contains(year)
            else { return nil }

            let identifier = String(doi.dropFirst(prefix.count))
            let landingID = String(landing.path.dropFirst(5))
            let versionRange = landingID.range(of: #"v[1-9][0-9]*$"#, options: .regularExpression)
            let base = String(landingID[..<(versionRange?.lowerBound ?? landingID.endIndex)])
            guard base.lowercased() == identifier else { return nil }
            var resolved = landingID
            if let version = attributes.version {
                guard let number = Int(version), number > 0, String(number) == version else { return nil }
                resolved = base + "v" + version
                guard versionRange == nil || resolved == landingID else { return nil }
            }
            guard let pdf = URL(string: "https://arxiv.org/pdf/" + resolved) else { return nil }
            var record = PaperCandidate(
                id: "https://arxiv.org/abs/" + resolved,
                title: title.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                authors: (attributes.creators ?? []).map(\.displayName).joined(separator: ", "),
                year: String(year), pdfURL: pdf)
            let publicationDOIs = Set(
                (attributes.relatedIdentifiers ?? []).compactMap { link -> String? in
                    guard link.relatedIdentifierType == "DOI",
                        ["IsVersionOf", "IsPreprintOf", "IsIdenticalTo"].contains(link.relationType),
                        let doi = link.relatedIdentifier.flatMap(PaperCandidate.normalizedDOI),
                        !doi.hasPrefix(prefix)
                    else { return nil }
                    return doi
                })
            if publicationDOIs.count == 1 { record.doi = publicationDOIs.first }
            record.indexedByDataCite = true
            return ArxivClient.verified(record)
        }
    }
}
