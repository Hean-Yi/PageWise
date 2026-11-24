import Foundation

struct IndexedOpenCopy: Sendable {
    let candidateID: String
    let url: URL
    let notice: String
}

/// Only consults these indexes for a selected result, never for every row in a search.
actor IndexedOpenCopies {
    private enum Index: CaseIterable { case openAlex, semanticScholar }
    private struct OpenAlexWork: Decodable {
        struct Location: Decodable {
            let isOpen: Bool?
            let pdfURL: String?
            let doi: String?
            let version: String?
            enum CodingKeys: String, CodingKey {
                case isOpen = "is_oa"
                case pdfURL = "pdf_url"
                case doi, version
            }
        }
        let doi: String?
        let locations: [Location]
    }

    private let transport: any HTTPTransport
    private let downloader: OpenAccessPDFDownloader
    private var retryAfter: [Index: Date] = [:]

    init(transport: any HTTPTransport) {
        self.transport = transport
        self.downloader = OpenAccessPDFDownloader(transport: transport)
    }

    func download(_ input: PaperCandidate) async throws -> DownloadedPublication {
        guard let candidate = input.verified, candidate.canAttemptDownload else {
            throw ReaderError.message("这条书目缺少可查询全文的编号，可在来源页获取 PDF。")
        }
        var attempted: Set<URL> = []
        var incomplete = false
        if let pdf = candidate.pdfURL {
            attempted.insert(pdf)
            do { return try await downloader.downloadPublication(candidate) } catch {
                try checkCancellation(error)
                incomplete = true
            }
        }
        for index in Index.allCases {
            try Task.checkCancellation()
            guard let request = request(for: candidate, index: index) else { continue }
            do {
                let copies = try await locations(for: candidate, at: index, request: request)
                var tries = 0
                for copy in copies {
                    var result = candidate
                    result.pdfURL = copy.url
                    result.indexedCopy = copy
                    guard let url = result.verified?.pdfURL, url == copy.url, attempted.insert(url).inserted else {
                        continue
                    }
                    tries += 1
                    do { return try await downloader.downloadPublication(result) } catch {
                        try checkCancellation(error)
                        incomplete = true
                    }
                    if tries == 3 { break }
                }
            } catch {
                try checkCancellation(error)
                incomplete = true
            }
        }
        if incomplete {
            throw ReaderError.message("部分全文服务暂时无法访问，可重试或从出版页获取 PDF。")
        }
        throw ReaderError.message("公开索引暂未提供这篇论文可核验的开放 PDF，可查看来源页或导入已有文件。")
    }

    private func checkCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        // A transfer rejected by the byte limit also reports URLError.cancelled.
        if error is CancellationError { throw CancellationError() }
    }

    private func request(for candidate: PaperCandidate, index: Index) -> URLRequest? {
        let base: String
        let identifier: String
        let fields: URLQueryItem
        switch index {
        case .openAlex:
            guard let doi = candidate.doi else { return nil }
            base = "https://api.openalex.org/works/https://doi.org/"
            identifier = doi
            fields = .init(name: "select", value: "doi,locations")
        case .semanticScholar:
            guard let id = candidate.doi.map({ "DOI:" + $0 }) ?? ScholarlyIndexes.recommendationID(candidate.id) else {
                return nil
            }
            base = "https://api.semanticscholar.org/graph/v1/paper/"
            identifier = id
            fields = .init(name: "fields", value: "externalIds,openAccessPdf")
        }
        var parts = URLComponents(string: base)!
        // Treat reserved characters in the identifier as data, not URL query or path syntax.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        parts.percentEncodedPath += encoded
        parts.queryItems = [fields]
        guard let url = parts.url else { return nil }
        return ScholarlyIndexes.metadataRequest(url, timeout: 8)
    }

    private func locations(for candidate: PaperCandidate, at index: Index, request: URLRequest) async throws
        -> [IndexedOpenCopy]
    {
        if let until = retryAfter[index], until > Date() { throw URLError(.resourceUnavailable) }
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.url == request.url else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { return [] }
        if response.statusCode == 429 || response.statusCode == 503 {
            let retry = ArxivMetadataRequests.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
            retryAfter[index] = retry ?? Date().addingTimeInterval(60)
        }
        guard response.statusCode == 200, data.count <= 1_000_000 else { throw URLError(.badServerResponse) }
        switch index {
        case .openAlex:
            let work = try JSONDecoder().decode(OpenAlexWork.self, from: data)
            guard let doi = work.doi.flatMap(PaperCandidate.queryDOI), doi == candidate.doi else {
                throw URLError(.cannotParseResponse)
            }
            // Submitted preprints retain their own search card and version-specific import route.
            return ["publishedVersion", "acceptedVersion"].flatMap { version in
                work.locations.compactMap { item -> IndexedOpenCopy? in
                    guard item.isOpen == true, item.version == version, let raw = item.pdfURL,
                        let url = URL(string: raw)
                    else { return nil }
                    if let locationDOI = item.doi, PaperCandidate.queryDOI(locationDOI) != doi { return nil }
                    let edition = version == "publishedVersion" ? "出版版" : "作者接收稿"
                    return IndexedOpenCopy(
                        candidateID: candidate.id, url: url, notice: "OpenAlex 收录的" + edition + " PDF。")
                }
            }
        case .semanticScholar:
            let work = try JSONDecoder().decode(ScholarRecord.self, from: data)
            if let doi = candidate.doi {
                guard work.externalIds?.doi.flatMap(PaperCandidate.normalizedDOI) == doi else {
                    throw URLError(.cannotParseResponse)
                }
            } else {
                guard let id = work.paperId, id.lowercased() == candidate.landingURL?.lastPathComponent.lowercased()
                else { throw URLError(.cannotParseResponse) }
            }
            guard let raw = work.openAccessPdf?.url, !raw.isEmpty, let url = URL(string: raw) else { return [] }
            return [.init(candidateID: candidate.id, url: url, notice: "Semantic Scholar 收录的开放全文，版本以 PDF 为准。")]
        }
    }
}
