import Foundation
import SwiftSoup

/// Pins an unversioned catalog record using the official abstract's identity and current version.
enum ArxivAbstractVersion {
    static func resolve(_ candidate: PaperCandidate, identifier: String, using transport: any HTTPTransport)
        async throws -> PaperCandidate
    {
        let url = URL(string: "https://arxiv.org/abs/" + identifier)!
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try Task.checkCancellation()
        guard response.statusCode == 200, response.url == url, data.count <= 2_000_000,
            let html = String(data: data, encoding: .utf8)
        else { throw ReaderError.message("无法读取 arXiv 摘要页以确认论文版本。") }
        return try parse(html, candidate: candidate, identifier: identifier)
    }

    static func parse(_ html: String, candidate: PaperCandidate, identifier: String) throws -> PaperCandidate {
        let invalid = ReaderError.message("arXiv 摘要页未能确认这篇论文的版本。")
        let document = try SwiftSoup.parse(html)
        guard let head = document.head(),
            try head.select("meta[name=citation_arxiv_id]").attr("content") == identifier
        else { throw invalid }

        var versions = Set<String>()
        if let permalink = try head.select("meta[property=og:url]").first() {
            let value = try permalink.attr("content")
            if value != "https://arxiv.org/abs/" + identifier {
                guard let id = ArxivClient.versionedIdentifier(value), id.hasPrefix(identifier + "v") else {
                    throw invalid
                }
                versions.insert(id)
            }
        }
        // The current version is plain bold text. Earlier versions are links inside bold tags.
        for marker in try document.select(".submission-history strong, #submission-history strong") {
            let label = marker.ownText()
            if label.range(of: #"^\[v[1-9][0-9]*\]$"#, options: .regularExpression) != nil {
                versions.insert(identifier + label.dropFirst().dropLast())
            }
        }
        guard versions.count == 1, let id = versions.first else { throw invalid }
        let title = try head.select("meta[name=citation_title]").attr("content")
        let abstract = try document.select("blockquote.abstract").first()
        try abstract?.select(".descriptor").remove()
        let pinned = PaperCandidate(
            id: "https://arxiv.org/abs/" + id, title: title.isEmpty ? candidate.title : title,
            authors: candidate.authors, year: candidate.year, pdfURL: URL(string: "https://arxiv.org/pdf/" + id)!,
            abstract: try abstract?.text())
        guard let verified = ArxivClient.verified(pinned) else { throw invalid }
        return verified
    }
}
