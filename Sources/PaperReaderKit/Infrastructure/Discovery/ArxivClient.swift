import Foundation

public struct PaperCandidate: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var authors: String
    public var year: String
    public var pdfURL: URL
    public init(id: String, title: String, authors: String, year: String, pdfURL: URL) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.pdfURL = pdfURL
    }
}

public protocol PaperDiscovery: Sendable {
    func search(_ query: String) async throws -> [PaperCandidate]
    func download(_ candidate: PaperCandidate) async throws -> URL
}

public actor ArxivClient: PaperDiscovery {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public func search(_ query: String) async throws -> [PaperCandidate] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let words = clean.split { !$0.isLetter && !$0.isNumber }.prefix(16)
        guard !words.isEmpty else { return [] }
        let titleQuery = words.map { "ti:\"\($0)\"" }.joined(separator: " AND ")
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            .init(name: "search_query", value: titleQuery),
            .init(name: "max_results", value: "8"),
        ]
        let (data, response) = try await transport.data(for: URLRequest(url: components.url!))
        try Task.checkCancellation()
        guard response.statusCode == 200, response.url == components.url, data.count <= 2_000_000 else {
            throw ReaderError.message("arXiv 暂时无法访问，请稍后重试或导入 PDF。")
        }
        let parser = XMLParser(data: data)
        let delegate = FeedParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ReaderError.message("无法解析 arXiv 搜索结果。") }
        return Array(delegate.results.prefix(8))
    }
    public func download(_ candidate: PaperCandidate) async throws -> URL {
        guard let candidate = Self.verified(candidate) else { throw ReaderError.message("论文下载来源无效。") }
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: URLRequest(url: candidate.pdfURL))
        try Task.checkCancellation()
        guard response.statusCode == 200, Self.trustedOrigin(response.url),
            response.url?.path == candidate.pdfURL.path, data.count <= 50_000_000,
            data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil
        else { throw ReaderError.message("全文下载失败或不是有效 PDF，可手动导入。") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            try data.write(to: target, options: .withoutOverwriting)
            try Task.checkCancellation()
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Only arXiv IDs and matching PDF paths can become import capabilities.
    public static func verified(_ candidate: PaperCandidate) -> PaperCandidate? {
        guard let source = URL(string: candidate.id), trustedOrigin(source), trustedOrigin(candidate.pdfURL),
            source.path.hasPrefix("/abs/"), candidate.pdfURL.path.hasPrefix("/pdf/")
        else { return nil }
        let identifier = String(source.path.dropFirst(5))
        let pdfID = String(candidate.pdfURL.path.dropFirst(5)).replacingOccurrences(
            of: #"\.pdf$"#, with: "", options: .regularExpression)
        let pattern = #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z-]+(?:\.[A-Za-z-]+)?/[0-9]{7})(?:v[1-9][0-9]*)?$"#
        guard identifier.range(of: pattern, options: .regularExpression) != nil, identifier == pdfID,
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
    private var fields: [String: String] = [:]
    private var current = ""
    private var inEntry = false
    private var pdf: String?
    private var authors: [String] = []
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = elementName
        if elementName == "entry" {
            inEntry = true
            fields = [:]
            pdf = nil
            authors = []
        }
        if elementName == "name" { fields["name"] = "" }
        if elementName == "link", attributeDict["title"] == "pdf" { pdf = attributeDict["href"] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry { fields[current, default: ""] += string }
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        if elementName == "name", let name = fields["name"] {
            authors.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "entry" {
            defer { inEntry = false }
            guard let rawID = fields["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                let rawTitle = fields["title"], let rawPDF = pdf,
                var components = URLComponents(string: rawPDF),
                var source = URLComponents(string: rawID),
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
                pdfURL: url)
            if let candidate = ArxivClient.verified(candidate) { results.append(candidate) }
        }
        current = ""
    }
}
