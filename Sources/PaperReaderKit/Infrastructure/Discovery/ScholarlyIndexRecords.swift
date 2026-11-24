import Foundation

/// Read only explicit preprint identifiers and official landing pages from an index's relationship metadata.
private func indexedArxivID(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = value.lowercased()
    let prefix = "10.48550/arxiv."
    if lower.hasPrefix(prefix) { return PaperCandidate.arxivIdentifier(String(value.dropFirst(prefix.count))) }
    if lower.hasPrefix("arxiv:") { return PaperCandidate.arxivIdentifier(String(value.dropFirst(6))) }
    if let url = URL(string: value), ["http", "https"].contains(url.scheme),
        url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil
    {
        if url.host == "arxiv.org", url.path.hasPrefix("/abs/") {
            return PaperCandidate.arxivIdentifier(String(url.path.dropFirst(5)))
        }
        if url.host == "doi.org", url.path.lowercased().hasPrefix("/" + prefix) {
            return PaperCandidate.arxivIdentifier(String(url.path.dropFirst(1 + prefix.count)))
        }
    }
    return PaperCandidate.arxivIdentifier(value)
}

struct CrossrefPage: Decodable {
    let message: Message

    struct Message: Decodable { let items: [Record] }

    struct Record: Decodable {
        struct Author: Decodable {
            let given: String?
            let family: String?
            let name: String?

            var displayName: String? {
                if let name, !name.isEmpty { return name }
                let pieces = [given, family].compactMap { $0 }.filter { !$0.isEmpty }
                return pieces.isEmpty ? nil : pieces.joined(separator: " ")
            }
        }

        struct Issued: Decodable {
            let parts: [[Int?]]?
            enum CodingKeys: String, CodingKey { case parts = "date-parts" }
        }

        struct Relation: Decodable { let id: String? }

        struct License: Decodable {
            struct Start: Decodable { let timestamp: Double? }
            let url: String?
            let version: String?
            let start: Start?
            enum CodingKeys: String, CodingKey {
                case url = "URL"
                case version = "content-version"
                case start
            }

            var coversPublishedVersion: Bool {
                guard version == "vor", let timestamp = start?.timestamp,
                    Date(timeIntervalSince1970: timestamp / 1000) <= Date(),
                    let url = url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme),
                    ["creativecommons.org", "www.creativecommons.org"].contains(url.host),
                    url.user == nil, url.password == nil, url.port == nil,
                    url.path.range(
                        of:
                            #"^/(?:licenses/by(?:-nc)?(?:-sa|-nd)?/(?:[1-4]\.0|2\.5)(?:/[a-z]{2})?|publicdomain/zero/1\.0)/?$"#,
                        options: .regularExpression) != nil
                else { return false }
                return true
            }
        }

        struct FullTextLink: Decodable {
            let url: String?
            let contentType: String?
            let version: String?
            enum CodingKeys: String, CodingKey {
                case url = "URL"
                case contentType = "content-type"
                case version = "content-version"
            }
        }

        let doi: String?
        let title: [String]?
        let author: [Author]?
        let issued: Issued?
        let relation: [String: [Relation]]?
        let license: [License]?
        let link: [FullTextLink]?
        enum CodingKeys: String, CodingKey {
            case doi = "DOI"
            case title, author, issued, relation, license, link
        }

        var candidate: PaperCandidate? {
            guard let doi = doi.flatMap(PaperCandidate.normalizedDOI), let title = title?.first else { return nil }
            let links = Set((relation?["has-preprint"] ?? []).compactMap { $0.id.flatMap(indexedArxivID) })
            let arxivID = indexedArxivID(doi) ?? (links.count == 1 ? links.first : nil)
            let year = issued?.parts?.first?.first.flatMap { $0 }
            var paper = PaperCandidate(
                id: "https://doi.org/" + doi, title: title.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                authors: (author ?? []).compactMap(\.displayName).joined(separator: ", "),
                year: year.map(String.init) ?? "",
                source: .crossref, doi: doi, relatedArxivID: arxivID)
            if license?.contains(where: \.coversPublishedVersion) == true {
                for link in link ?? [] where link.version == "vor" && link.contentType == "application/pdf" {
                    paper.pdfURL = link.url.flatMap(URL.init(string:))
                    if let checked = OpenAccessPDFDownloader.verifiedURL(for: paper) {
                        paper.pdfURL = checked
                        return paper
                    }
                }
                paper.pdfURL = nil
            }
            return paper
        }
    }
}

// DBLP serializes one author or edition as an object/string, several as an array.
private struct OneOrMany<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let elements = try? value.decode([Element].self) {
            values = elements
        } else {
            values = [try value.decode(Element.self)]
        }
    }
}

struct DBLPPage: Decodable {
    let result: Result

    struct Result: Decodable { let hits: Hits }

    struct Hits: Decodable {
        let total: String?
        let hit: [Hit]?
        enum CodingKeys: String, CodingKey {
            case total = "@total"
            case hit
        }
    }

    struct Hit: Decodable { let info: Record? }

    struct Record: Decodable {
        struct Author: Decodable {
            let name: String

            enum CodingKeys: String, CodingKey { case text }

            init(from decoder: any Decoder) throws {
                if let scalar = try? decoder.singleValueContainer().decode(String.self) {
                    name = scalar
                } else {
                    name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .text)
                }
            }
        }

        struct Authors: Decodable { fileprivate let author: OneOrMany<Author>? }

        let title: String?
        let key: String?
        let year: String?
        let authors: Authors?
        let doi: String?
        private let ee: OneOrMany<String>?

        var candidate: PaperCandidate? {
            guard let title else { return nil }
            let editions = ee?.values ?? []
            let editionDOIs = Set(
                editions.compactMap { edition -> String? in
                    guard let url = PaperCandidate.publicationURL(edition), url.host == "doi.org" else { return nil }
                    return PaperCandidate.normalizedDOI(String(url.path.dropFirst()))
                })
            let doi = doi.flatMap(PaperCandidate.normalizedDOI) ?? (editionDOIs.count == 1 ? editionDOIs.first : nil)
            let id: String
            if let doi {
                id = "https://doi.org/" + doi
            } else if let key {
                id = "https://dblp.org/rec/" + key
            } else {
                return nil
            }
            let links = Set(editions.compactMap(indexedArxivID))
            let arxivID = doi.flatMap(indexedArxivID) ?? (links.count == 1 ? links.first : nil)
            return PaperCandidate(
                id: id, title: title, authors: (authors?.author?.values ?? []).map(\.name).joined(separator: ", "),
                year: year ?? "", source: .dblp, doi: doi, relatedArxivID: arxivID)
        }
    }
}

struct ScholarSearchPage: Decodable { let data: [ScholarRecord] }
struct ScholarRecommendations: Decodable { let recommendedPapers: [ScholarRecord] }

struct ScholarRecord: Decodable {
    struct Author: Decodable { let name: String? }
    struct ExternalIDs: Decodable {
        let doi: String?
        let arxiv: String?
        enum CodingKeys: String, CodingKey {
            case doi = "DOI"
            case arxiv = "ArXiv"
        }
    }
    struct OpenPDF: Decodable { let url: String? }

    let paperId: String?
    let title: String?
    let authors: [Author]?
    let year: Int?
    let externalIds: ExternalIDs?
    let openAccessPdf: OpenPDF?

    var candidate: PaperCandidate? {
        guard let title, let paperId, paperId.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil
        else { return nil }
        let doi = externalIds?.doi.flatMap(PaperCandidate.normalizedDOI)
        let arxivID = externalIds?.arxiv.flatMap(indexedArxivID) ?? doi.flatMap(indexedArxivID)
        let pdf = openAccessPdf?.url.flatMap(URL.init(string:))
        return PaperCandidate(
            id: doi.map { "https://doi.org/" + $0 } ?? "https://www.semanticscholar.org/paper/" + paperId.lowercased(),
            title: title, authors: (authors ?? []).compactMap(\.name).joined(separator: ", "),
            year: year.map(String.init) ?? "", pdfURL: pdf, source: .semanticScholar, doi: doi, relatedArxivID: arxivID)
    }
}
