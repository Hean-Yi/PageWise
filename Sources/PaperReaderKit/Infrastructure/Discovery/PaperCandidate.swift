import Foundation

public enum PaperSearchSource: String, Sendable, CaseIterable {
    case arxiv, crossref, dblp, semanticScholar

    public var label: String {
        switch self {
        case .arxiv: "arXiv"
        case .crossref: "Crossref"
        case .dblp: "DBLP"
        case .semanticScholar: "Semantic Scholar"
        }
    }
}

public enum PaperSearchScope: String, Sendable, CaseIterable {
    case all, arxiv, crossref, dblp

    var sources: [PaperSearchSource] {
        switch self {
        case .all: [.arxiv, .crossref, .dblp]
        case .arxiv: [.arxiv]
        case .crossref: [.crossref]
        case .dblp: [.dblp]
        }
    }
}

public struct PaperCandidate: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var authors: String
    public var year: String
    public var pdfURL: URL?
    public var source: PaperSearchSource
    public var doi: String?
    /// Explicit identifier supplied by a scholarly index for the corresponding preprint.
    public var relatedArxivID: String?
    public var alternateVersions: [PaperCandidate] = []
    public var indexedByDataCite = false

    public init(
        id: String, title: String, authors: String, year: String, pdfURL: URL? = nil,
        source: PaperSearchSource = .arxiv, doi: String? = nil, relatedArxivID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.pdfURL = pdfURL
        self.source = source
        self.doi = doi
        self.relatedArxivID = relatedArxivID
    }

    public var verified: Self? {
        guard var record = verifiedRecord else { return nil }
        record.alternateVersions = alternateVersions.compactMap(\.verifiedRecord)
        return record
    }

    public var landingURL: URL? { verifiedRecord.flatMap { URL(string: $0.id) } }
    public var landingPageLabel: String { Self.landingPageLabel(for: landingURL) }
    public static func landingPageLabel(for url: URL?) -> String { url?.host == "doi.org" ? "查看出版页" : "查看来源页" }
    public var canDownload: Bool { verifiedRecord?.pdfURL != nil }

    private var verifiedRecord: Self? {
        var record = self
        record.alternateVersions = []
        if source == .arxiv { return ArxivClient.verified(record) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 2_000,
            authors.utf8.count <= 8_000, year.utf8.count <= 16,
            let url = Self.publicationURL(id), let host = url.host
        else { return nil }
        record.doi = doi.flatMap(Self.normalizedDOI)
        record.relatedArxivID = relatedArxivID.flatMap(Self.arxivIdentifier)
        switch host {
        case "doi.org":
            guard let identifier = Self.normalizedDOI(String(url.path.dropFirst())),
                doi == nil || record.doi == identifier
            else { return nil }
            record.doi = identifier
        case "dblp.org":
            guard source == .dblp,
                url.path.range(of: #"^/rec/[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
            else { return nil }
        case "www.semanticscholar.org":
            guard source == .semanticScholar,
                url.path.range(of: #"^/paper/[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil
            else { return nil }
        default: return nil
        }
        record.pdfURL = OpenAccessPDFDownloader.verifiedURL(for: record)
        return record
    }

    static func publicationURL(_ id: String) -> URL? {
        guard id.utf8.count <= 2_048, let url = URL(string: id), url.scheme == "https",
            url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
            !url.pathComponents.contains(".."), !url.pathComponents.contains(".")
        else { return nil }
        return url
    }

    static func queryDOI(_ value: String) -> String? {
        if let url = publicationURL(value), url.host == "doi.org" {
            return normalizedDOI(String(url.path.dropFirst()))
        }
        let raw = value.lowercased().hasPrefix("doi:") ? String(value.dropFirst(4)) : value
        return normalizedDOI(raw)
    }

    static func normalizedDOI(_ raw: String) -> String? {
        let doi = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard doi.utf8.count <= 1_024, !doi.contains("\\"), !doi.contains("%"),
            doi.range(of: #"^10\.[0-9]{4,9}/[^\s\p{C}?#]+$"#, options: .regularExpression) != nil
        else { return nil }
        return doi
    }

    static func arxivIdentifier(_ raw: String) -> String? {
        guard
            raw.range(
                of: #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z-]+(?:\.[A-Za-z-]+)?/[0-9]{7})(?:v[1-9][0-9]*)?$"#,
                options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    var preprintID: String? {
        if source == .arxiv, let url = URL(string: id), url.path.hasPrefix("/abs/") {
            return Self.arxivIdentifier(String(url.path.dropFirst(5)))
        }
        return relatedArxivID.flatMap(Self.arxivIdentifier)
    }

    var linkedPreprint: Self? {
        guard source != .arxiv, let identifier = preprintID else { return nil }
        return Self(
            id: "https://arxiv.org/abs/" + identifier, title: title, authors: authors, year: year,
            pdfURL: URL(string: "https://arxiv.org/pdf/" + identifier))
    }
}

public struct OnlineDiscoveryResult: Sendable {
    public let candidates: [PaperCandidate]
    public let notice: String?
    public init(candidates: [PaperCandidate], notice: String? = nil) {
        self.candidates = candidates
        self.notice = notice
    }
}
