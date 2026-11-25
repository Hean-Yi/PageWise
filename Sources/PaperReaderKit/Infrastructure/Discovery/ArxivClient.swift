import Foundation

public protocol PaperDiscovery: Sendable {
    func search(_ query: String) async throws -> [PaperCandidate]
    func search(_ query: String, limit: Int) async throws -> [PaperCandidate]
    func discover(
        _ query: String, scope: PaperSearchScope, limit: Int, onUpdate: @Sendable (OnlineDiscoveryResult) async -> Void
    ) async throws -> OnlineDiscoveryResult
    func related(title: String, sourceID: String?, limit: Int) async throws -> [PaperCandidate]
    func download(_ candidate: PaperCandidate) async throws -> URL
    func structuredContent(_ candidate: PaperCandidate) async throws -> [TextBlock]?
    func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication
}

extension PaperDiscovery {
    public func discover(_ query: String, scope: PaperSearchScope, limit: Int) async throws -> OnlineDiscoveryResult {
        try await discover(query, scope: scope, limit: limit) { _ in }
    }
    public func discover(
        _ query: String, scope: PaperSearchScope, limit: Int, onUpdate: @Sendable (OnlineDiscoveryResult) async -> Void
    ) async throws -> OnlineDiscoveryResult {
        guard scope == .all || scope == .arxiv else { throw ReaderError.message("此服务不支持所选检索源。") }
        return OnlineDiscoveryResult(candidates: try await search(query, limit: limit))
    }
    public func related(title: String, sourceID: String?, limit: Int) async throws -> [PaperCandidate] {
        throw ReaderError.message("此服务不支持相关论文推荐。")
    }
    public func search(_ query: String, limit: Int) async throws -> [PaperCandidate] {
        guard limit > 0 else { return [] }
        return Array(try await search(query).prefix(limit))
    }
    public func structuredContent(_ candidate: PaperCandidate) async throws -> [TextBlock]? { nil }
    public func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication {
        DownloadedPublication(pdfURL: try await download(candidate), candidate: candidate)
    }
}

public struct DownloadedPublication: Sendable {
    public var pdfURL: URL
    public var candidate: PaperCandidate
    public var texArchive: Data?
    public var sourceNotice: String?
    public init(pdfURL: URL, candidate: PaperCandidate, texArchive: Data? = nil, sourceNotice: String? = nil) {
        self.pdfURL = pdfURL
        self.candidate = candidate
        self.texArchive = texArchive
        self.sourceNotice = sourceNotice
    }
}

public actor ArxivClient: PaperDiscovery {
    private let transport: any HTTPTransport
    private let metadataRequests: ArxivMetadataRequests
    public init() {
        self.init(transport: NetworkTransport(), metadataRequests: .shared)
    }
    public init(transport: any HTTPTransport) {
        self.init(transport: transport, metadataRequests: ArxivMetadataRequests())
    }
    init(transport: any HTTPTransport, metadataRequests: ArxivMetadataRequests) {
        self.transport = transport
        self.metadataRequests = metadataRequests
    }
    public func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication {
        guard let candidate = Self.verified(candidate) else { throw ReaderError.message("论文下载来源无效。") }
        // Search normally returns a version. Resolve older unversioned candidates before either download.
        let pinned: PaperCandidate
        if Self.versionedIdentifier(candidate.id) != nil {
            pinned = candidate
        } else {
            let identifier = String(URL(string: candidate.id)!.path.dropFirst(5))
            var components = URLComponents(string: "https://export.arxiv.org/api/query")!
            components.queryItems = [.init(name: "id_list", value: identifier)]
            do {
                let results = try await metadata(components)
                guard results.count == 1, let result = results.first,
                    let resolved = Self.versionedIdentifier(result.id),
                    resolved.replacingOccurrences(of: #"v[1-9][0-9]*$"#, with: "", options: .regularExpression)
                        == identifier
                else { throw ReaderError.message("无法确认论文版本，请重新查找。") }
                pinned = result
            } catch let error as ArxivQueryError where error.allowsMetadataFallback {
                pinned = try await ArxivAbstractVersion.resolve(candidate, identifier: identifier, using: transport)
            }
        }
        let identifier = Self.versionedIdentifier(pinned.id)!
        let sourceURL = URL(string: "https://arxiv.org/src/" + identifier)!
        var archive: Data?
        var notice: String?
        do {
            let (file, response) = try await transport.downloadFile(
                for: URLRequest(url: sourceURL), maximumBytes: 50_000_000)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard response.statusCode == 200, Self.trustedOrigin(response.url),
                response.url?.path == sourceURL.path
            else { throw ReaderError.message("此版本没有可用的 TeX 源码包。") }
            // The mapping retains the downloaded bytes after unlink, until import finishes or fails.
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            guard TeXArchive.looksLikeSource(data)
            else { throw ReaderError.message("此版本没有可用的 TeX 源码包。") }
            archive = data
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            notice = "TeX 源码包未能获取；重排时将尝试同版本 HTML；原版 PDF 仍可阅读。"
        }
        let pdf = try await download(pinned)
        return DownloadedPublication(pdfURL: pdf, candidate: pinned, texArchive: archive, sourceNotice: notice)
    }

    public static func versionedIdentifier(_ id: String) -> String? {
        guard let url = URL(string: id), trustedOrigin(url), url.path.hasPrefix("/abs/") else { return nil }
        let value = String(url.path.dropFirst(5))
        guard
            value.range(
                of: #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z-]+(?:\.[A-Za-z-]+)?/[0-9]{7})v[1-9][0-9]*$"#,
                options: .regularExpression) != nil
        else { return nil }
        return value
    }
    public func structuredContent(_ candidate: PaperCandidate) async throws -> [TextBlock]? {
        guard let candidate = Self.verified(candidate), let source = URL(string: candidate.id),
            source.path.range(of: #"v[1-9][0-9]*$"#, options: .regularExpression) != nil,
            let url = URL(string: "https://arxiv.org/html/" + source.path.dropFirst(5))
        else { return nil }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try Task.checkCancellation()
        guard response.statusCode == 200, response.url == url else { return nil }
        return try await HTMLPaperParser(transport: transport).parse(data, at: url)
    }
    public func search(_ query: String) async throws -> [PaperCandidate] {
        try await search(query, limit: 8)
    }

    public func search(_ query: String, limit: Int) async throws -> [PaperCandidate] {
        let limit = min(limit, 40)
        guard limit > 0 else { return [] }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let words = clean.split { !$0.isLetter && !$0.isNumber }.prefix(16)
        guard !words.isEmpty else { return [] }
        guard words.reduce(0, { $0 + $1.utf8.count }) <= 4_096 else { throw ArxivQueryError.invalidQuery }
        let titleQuery = words.map { "ti:\"\($0)\"" }.joined(separator: " AND ")
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            .init(name: "search_query", value: titleQuery),
            .init(name: "max_results", value: String(limit)),
        ]
        guard let url = components.url else { throw ArxivQueryError.invalidQuery }
        return try await metadataRequests.results(
            for: url, using: transport, searchKey: titleQuery.lowercased(), limit: limit,
            doiQuery: words.joined(separator: " "))
    }

    private func metadata(_ components: URLComponents) async throws
        -> [PaperCandidate]
    {
        guard let url = components.url else { throw ArxivQueryError.invalidQuery }
        return try await metadataRequests.results(for: url, using: transport, searchKey: nil, limit: 40)
    }

    static func parseMetadata(_ data: Data) throws -> [PaperCandidate] {
        let parser = XMLParser(data: data)
        let delegate = FeedParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.root == "feed" else { throw ArxivQueryError.invalidResponse }
        if delegate.hasQueryError { throw ArxivQueryError.invalidQuery }
        guard !delegate.results.isEmpty || (!delegate.sawEntry && (delegate.totalResults ?? 0) == 0) else {
            throw ArxivQueryError.invalidResponse
        }
        return delegate.results
    }
    public func download(_ candidate: PaperCandidate) async throws -> URL {
        guard let candidate = Self.verified(candidate), let pdfURL = candidate.pdfURL else {
            throw ReaderError.message("论文下载来源无效。")
        }
        try Task.checkCancellation()
        let (file, response) = try await transport.downloadFile(for: URLRequest(url: pdfURL), maximumBytes: 50_000_000)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard response.statusCode == 200, Self.trustedOrigin(response.url), response.url?.path == pdfURL.path,
            let prefix = try handle.read(upToCount: 1_024), prefix.range(of: Data("%PDF-".utf8)) != nil
        else { throw ReaderError.message("全文下载失败或不是有效 PDF，可手动导入。") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            try FileManager.default.moveItem(at: file, to: target)
            try Task.checkCancellation()
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Only arXiv IDs and matching PDF paths can become import capabilities.
    public static func verified(_ candidate: PaperCandidate) -> PaperCandidate? {
        guard candidate.source == .arxiv, let source = URL(string: candidate.id), trustedOrigin(source),
            let pdfURL = candidate.pdfURL, trustedOrigin(pdfURL),
            source.path.hasPrefix("/abs/"), pdfURL.path.hasPrefix("/pdf/")
        else { return nil }
        let identifier = String(source.path.dropFirst(5))
        let pdfID = String(pdfURL.path.dropFirst(5)).replacingOccurrences(
            of: #"\.pdf$"#, with: "", options: .regularExpression)
        guard PaperCandidate.arxivIdentifier(identifier) != nil, identifier == pdfID,
            !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            candidate.title.utf8.count <= 2_000, candidate.authors.utf8.count <= 8_000,
            candidate.year.utf8.count <= 16
        else { return nil }
        return candidate
    }

    private static func trustedOrigin(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", ["arxiv.org", "export.arxiv.org"].contains(url.host ?? ""),
            url.user == nil, url.password == nil, url.port == nil || url.port == 443,
            url.query == nil, url.fragment == nil
        else { return false }
        return true
    }
    public static func normalized(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    var results: [PaperCandidate] = []
    private(set) var root: String?
    private(set) var hasQueryError = false
    private(set) var sawEntry = false
    private(set) var totalResults: Int?
    private var fields: [String: String] = [:]
    private var current = ""
    private var inEntry = false
    private var pdf: String?
    private var authors: [String] = []
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if root == nil {
            root =
                namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://www.w3.org/2005/Atom"
                ? elementName : ""
        }
        current = namespaceURI == "http://arxiv.org/schemas/atom" && elementName == "doi" ? "arxiv:doi" : elementName
        if elementName == "entry" {
            sawEntry = true
            inEntry = true
            fields = [:]
            pdf = nil
            authors = []
        }
        if elementName == "name" { fields["name"] = "" }
        if inEntry, elementName == "link", attributeDict["title"] == "pdf" || attributeDict["type"] == "application/pdf"
        {
            pdf = attributeDict["href"]
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry || current == "totalResults" { fields[current, default: ""] += string }
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        if !inEntry, elementName == "totalResults", let count = fields.removeValue(forKey: elementName) {
            totalResults = Int(count.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "name", let name = fields["name"] {
            authors.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "entry" {
            defer { inEntry = false }
            guard let rawID = fields["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                var source = URLComponents(string: rawID)
            else { return }
            if source.path == "/api/errors", ["arxiv.org", "export.arxiv.org"].contains(source.host ?? "") {
                hasQueryError = true
                return
            }
            guard let rawTitle = fields["title"], let rawPDF = pdf, var components = URLComponents(string: rawPDF),
                ["http", "https"].contains(components.scheme ?? ""),
                ["http", "https"].contains(source.scheme ?? "")
            else { return }
            components.scheme = "https"
            source.scheme = "https"
            guard let url = components.url, let sourceURL = source.url else { return }
            let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let candidate = PaperCandidate(
                id: sourceURL.absoluteString, title: title, authors: authors.joined(separator: ", "),
                year: String((fields["published"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)),
                pdfURL: url, doi: fields["arxiv:doi"].flatMap(PaperCandidate.normalizedDOI), abstract: fields["summary"]
            )
            if let candidate = ArxivClient.verified(candidate) { results.append(candidate) }
        }
        current = ""
    }
}
