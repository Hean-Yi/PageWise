import Foundation

/// Public bibliographic services share cache entries across discovery surfaces, but observe separate cooldowns.
actor ScholarlyIndexes {
    enum Failure: LocalizedError {
        case invalidQuery
        case unavailable(PaperSearchSource)
        case http(PaperSearchSource, Int)
        case rateLimited(PaperSearchSource, Date)
        case browserVerification
        case unknownSeed, ambiguousTitle

        var errorDescription: String? {
            switch self {
            case .invalidQuery: "检索词无效。"
            case .unavailable(let source): "\(source.label) 暂时未能提供可读取的检索结果。"
            case .http(let source, let status): "\(source.label) 暂时无法完成检索（HTTP \(status)）。"
            case .rateLimited(let source, let until):
                "\(source.label) 暂时限制请求，可在 \(until.formatted(date: .omitted, time: .standard)) 后重试。"
            case .browserVerification: "DBLP 此次要求浏览器验证，暂时无法获取检索结果。"
            case .unknownSeed: "Semantic Scholar 尚未找到这篇论文的对应记录。"
            case .ambiguousTitle: "Semantic Scholar 中有多篇同名论文，需要 DOI 或 arXiv 编号来确定推荐依据。"
            }
        }
    }

    private let transport: any HTTPTransport
    private var retryAfter: [PaperSearchSource: Date] = [:]
    private var dblpVerificationUntil: Date?
    private var cache: [URL: (expires: Date, records: [PaperCandidate])] = [:]
    private typealias Waiter = (id: UUID, continuation: CheckedContinuation<Void, any Error>)
    private var queues: [PaperSearchSource: [Waiter]] = [:]

    init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    func crossref(_ query: String, limit: Int) async throws -> [PaperCandidate] {
        guard let (query, count) = try Self.parameters(query, limit: limit) else { return [] }
        var components = URLComponents(string: "https://api.crossref.org/works")!
        var items: [URLQueryItem] = [
            .init(name: "rows", value: String(count)),
            .init(name: "select", value: "DOI,title,author,issued,relation,license,link,abstract"),
        ]
        let exactDOI = PaperCandidate.queryDOI(query)
        if let doi = exactDOI {
            items.append(.init(name: "filter", value: "doi:" + doi))
        } else {
            items.append(.init(name: "query.bibliographic", value: query))
            items.append(
                .init(name: "filter", value: "type:journal-article,type:proceedings-article,type:posted-content"))
        }
        components.queryItems = items
        return try await records(components, source: .crossref, limit: count) { data in
            let page = try JSONDecoder().decode(CrossrefPage.self, from: data)
            return page.message.items.map { row in
                guard let candidate = row.candidate, exactDOI == nil || candidate.doi == exactDOI else { return nil }
                return candidate
            }
        }
    }

    func dblp(_ query: String, limit: Int) async throws -> [PaperCandidate] {
        guard let (query, count) = try Self.parameters(query, limit: limit) else { return [] }
        var components = URLComponents(string: "https://dblp.org/search/publ/api")!
        components.queryItems = [
            .init(name: "q", value: query), .init(name: "format", value: "json"),
            .init(name: "h", value: String(count)),
        ]
        return try await records(components, source: .dblp, limit: count) { data in
            let hits = try JSONDecoder().decode(DBLPPage.self, from: data).result.hits
            guard let rows = hits.hit else {
                guard hits.total == "0" else { throw Failure.unavailable(.dblp) }
                return []
            }
            return rows.map { $0.info?.candidate }
        }
    }

    func related(to seed: String, limit: Int) async throws -> [PaperCandidate] {
        guard limit > 0 else { return [] }
        guard let identifier = Self.recommendationID(seed) else { throw Failure.unknownSeed }
        let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: pathCharacters) else {
            throw Failure.invalidQuery
        }
        var components = URLComponents(string: "https://api.semanticscholar.org")!
        components.percentEncodedPath = "/recommendations/v1/papers/forpaper/" + encoded
        components.queryItems = [
            .init(name: "limit", value: String(min(limit, 40))),
            .init(name: "fields", value: "title,authors,year,externalIds,openAccessPdf,abstract"),
        ]
        return try await records(components, source: .semanticScholar, limit: limit) { data in
            try JSONDecoder().decode(ScholarRecommendations.self, from: data).recommendedPapers.map(\.candidate)
        }
    }

    func relatedByTitle(_ title: String, limit: Int) async throws -> [PaperCandidate] {
        guard let (title, count) = try Self.parameters(title, limit: limit) else { return [] }
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")!
        components.queryItems = [
            .init(name: "query", value: title), .init(name: "limit", value: "10"),
            .init(name: "fields", value: "title"),
        ]
        let results = try await records(components, source: .semanticScholar, limit: 10) { data in
            try JSONDecoder().decode(ScholarSearchPage.self, from: data).data.map(\.candidate)
        }
        let normalizedTitle = ArxivClient.normalized(title)
        let matches = results.filter { ArxivClient.normalized($0.title) == normalizedTitle }
        guard let match = matches.first else { throw Failure.unknownSeed }
        guard matches.count == 1 else { throw Failure.ambiguousTitle }
        return try await related(to: match.id, limit: count)
    }

    private static func parameters(_ input: String, limit: Int) throws -> (String, Int)? {
        let query = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !query.isEmpty, limit > 0 else { return nil }
        guard query.utf8.count <= 4_096 else { throw Failure.invalidQuery }
        return (query, min(limit, 40))
    }

    static func recommendationID(_ value: String) -> String? {
        if let doi = PaperCandidate.queryDOI(value) { return "DOI:" + doi }
        let landing = PaperCandidate.publicationURL(value)
        var arxiv = value
        if value.lowercased().hasPrefix("arxiv:") { arxiv = String(value.dropFirst(6)) }
        if let landing, ["arxiv.org", "export.arxiv.org"].contains(landing.host), landing.path.hasPrefix("/abs/") {
            arxiv = String(landing.path.dropFirst(5))
        }
        if let id = PaperCandidate.arxivIdentifier(arxiv) {
            return "ARXIV:" + id.replacingOccurrences(of: #"v[1-9][0-9]*$"#, with: "", options: .regularExpression)
        }
        let scholarID: String
        if let landing, landing.host == "www.semanticscholar.org", landing.path.hasPrefix("/paper/") {
            scholarID = String(landing.path.dropFirst(7))
        } else {
            scholarID = value
        }
        guard scholarID.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil else { return nil }
        return scholarID.lowercased()
    }

    private func records(
        _ components: URLComponents, source: PaperSearchSource, limit: Int,
        decode: (Data) throws -> [PaperCandidate?]
    ) async throws -> [PaperCandidate] {
        try Task.checkCancellation()
        var components = components
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw Failure.invalidQuery }
        if let entry = cache[url], entry.expires > Date() { return entry.records }
        try await acquire(source)
        defer { release(source) }
        try Task.checkCancellation()
        if let entry = cache[url], entry.expires > Date() { return entry.records }
        if let until = retryAfter[source], until > Date() { throw Failure.rateLimited(source, until) }
        if source == .dblp, let until = dblpVerificationUntil, until > Date() { throw Failure.browserVerification }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PaperReader/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Failure.unavailable(source)
        }
        try Task.checkCancellation()
        guard response.url == url else { throw Failure.unavailable(source) }
        let retry = ArxivMetadataRequests.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
        if response.statusCode == 429 || (response.statusCode == 503 && retry != nil) {
            let until = max(retryAfter[source] ?? .distantPast, retry ?? Date().addingTimeInterval(60))
            retryAfter[source] = until
            throw Failure.rateLimited(source, until)
        }
        if response.statusCode == 404, source == .semanticScholar { throw Failure.unknownSeed }
        if source == .dblp, [200, 202, 403].contains(response.statusCode),
            response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
        {
            dblpVerificationUntil = Date().addingTimeInterval(60)
            throw Failure.browserVerification
        }
        guard response.statusCode == 200 else { throw Failure.http(source, response.statusCode) }
        guard data.count <= 3_000_000, let rows = try? decode(data) else { throw Failure.unavailable(source) }
        var seen = Set<String>()
        let records = Array(rows.compactMap { $0?.verified }.filter { seen.insert($0.id).inserted }.prefix(limit))
        guard rows.isEmpty || !records.isEmpty else { throw Failure.unavailable(source) }
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.expires < $1.value.expires }) {
            cache.removeValue(forKey: oldest.key)
        }
        cache[url] = (Date().addingTimeInterval(600), records)
        return records
    }

    // One active metadata request per service, with independently cancellable waiters.
    private func acquire(_ source: PaperSearchSource) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if queues[source] == nil {
                    queues[source] = []
                    continuation.resume()
                } else {
                    queues[source]?.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, for: source) }
        }
    }

    private func cancelWaiter(_ id: UUID, for source: PaperSearchSource) {
        guard let index = queues[source]?.firstIndex(where: { $0.id == id }) else { return }
        queues[source]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ source: PaperSearchSource) {
        if queues[source]?.isEmpty == false {
            queues[source]?.removeFirst().continuation.resume()
        } else {
            queues.removeValue(forKey: source)
        }
    }
}
