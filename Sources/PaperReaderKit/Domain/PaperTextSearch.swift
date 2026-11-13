import Foundation

public struct PaperSearchResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let paperID: UUID
    public let text: String
    public let sourcePage: Int
    public let blockID: UUID?
    public let isTranslation: Bool
}

public enum PaperTextSearch {
    public static let maximumResults = 50

    /// Searches extracted text and translations already represented by published pages.
    public static func search(
        _ query: String, in paper: Paper, excluding pending: Set<UUID> = []
    ) -> [PaperSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let published = Set(
            paper.translatedPages.filter { !pending.contains($0.id) }.flatMap(\.blockIDs))
        let completed = Set(paper.blocks.prefix(max(0, paper.translatedBlockCount)).map(\.id))
        var results: [PaperSearchResult] = []
        for block in paper.blocks where block.sourcePage >= 0 && block.sourcePage < paper.pageCount {
            var texts = [(text: block.text, translated: false)]
            if published.contains(block.id), completed.contains(block.id),
                let translation = paper.translations[block.id.uuidString]
            {
                texts.append((text: translation, translated: true))
            }
            for candidate in texts {
                guard let match = candidate.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
                else { continue }
                results.append(
                    PaperSearchResult(
                        id: "\(paper.id.uuidString)-\(block.id.uuidString)-\(candidate.translated)",
                        paperID: paper.id, text: excerpt(candidate.text, around: match), sourcePage: block.sourcePage,
                        blockID: block.id, isTranslation: candidate.translated))
                if results.count == maximumResults { return results }
            }
        }
        return results
    }

    private static func excerpt(_ text: String, around match: Range<String.Index>) -> String {
        let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
