import Foundation

public struct PaperCandidate: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var authors: String
    public var year: String
    public var pdfURL: URL
}

public actor ArxivClient {
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
        guard response.statusCode == 200 else {
            throw ReaderError.message("arXiv 暂时无法访问，请稍后重试或导入 PDF。")
        }
        let parser = XMLParser(data: data)
        let delegate = FeedParser()
        parser.delegate = delegate
        guard parser.parse() else { throw ReaderError.message("无法解析 arXiv 搜索结果。") }
        return delegate.results
    }
    public func download(_ candidate: PaperCandidate) async throws -> URL {
        guard candidate.pdfURL.scheme == "https",
            ["arxiv.org", "export.arxiv.org"].contains(candidate.pdfURL.host ?? "")
        else {
            throw ReaderError.message("论文下载来源无效。")
        }
        let (location, response) = try await URLSession.shared.download(from: candidate.pdfURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReaderError.message("全文下载失败，可手动导入 PDF。") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try FileManager.default.moveItem(at: location, to: target)
        return target
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
                var components = URLComponents(string: rawPDF)
            else { return }
            components.scheme = "https"
            guard let url = components.url else { return }
            let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            results.append(
                PaperCandidate(
                    id: rawID, title: title, authors: authors.joined(separator: ", "),
                    year: String((fields["published"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)),
                    pdfURL: url))
        }
        current = ""
    }
}
