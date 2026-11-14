import Foundation

public struct PaperSearchResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let paperID: UUID
    public let text: String
    public let sourcePage: Int
    public let blockID: UUID?
    public let isTranslation: Bool
    public let matchedText: String
    public let matchingContext: String
    public let hasAmbiguousTranslationContext: Bool
}

public protocol FixedPageTextLocating: Sendable {
    func pageKey(matching matchedText: String, in pages: [PageArtifact], root: URL) async throws -> String?
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
        for block in paper.blocks
        where (block.sourcePage >= 0 && block.sourcePage < paper.pageCount) || published.contains(block.id) {
            var texts = [(text: block.text, translated: false)]
            if published.contains(block.id), completed.contains(block.id),
                let translation = paper.translations[block.id.uuidString]
            {
                texts.append((text: translation, translated: true))
            }
            for candidate in texts {
                guard let match = candidate.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
                else { continue }
                let context = matchingContext(candidate.text, around: match)
                let ambiguous =
                    candidate.translated
                    && paper.blocks.contains {
                        $0.sourcePage == block.sourcePage && containsLocationContext(context, in: $0.text)
                    }
                results.append(
                    PaperSearchResult(
                        id: "\(paper.id.uuidString)-\(block.id.uuidString)-\(candidate.translated)",
                        paperID: paper.id, text: excerpt(candidate.text, around: match), sourcePage: block.sourcePage,
                        blockID: block.id, isTranslation: candidate.translated,
                        matchedText: String(candidate.text[match]), matchingContext: context,
                        hasAmbiguousTranslationContext: ambiguous))
                if results.count == maximumResults { return results }
            }
        }
        return results
    }

    static func containsLocationContext(_ context: String, in text: String) -> Bool {
        // PDFKit may insert line breaks inside a phrase, including between adjacent CJK characters.
        let query = context.filter { !$0.isWhitespace }
        guard !query.isEmpty else { return false }
        return text.filter { !$0.isWhitespace }.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            != nil
    }

    private static func matchingContext(_ text: String, around match: Range<String.Index>) -> String {
        let start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    private static func excerpt(_ text: String, around match: Range<String.Index>) -> String {
        let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
