import Foundation

public struct AgentSearchHit: Sendable {
    public var paperID: UUID
    public var title: String
    public var blockID: UUID?
    public var sourcePage: Int?
    public var excerpt: String
    public var score: Int
}

public enum LibraryAgentSearch {
    public static func search(_ query: String, papers: [Paper], limit: Int = 8) -> [AgentSearchHit] {
        let terms = Set(normalized(query).split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !terms.isEmpty, limit > 0 else { return [] }
        return papers.compactMap { paper -> AgentSearchHit? in
            let title = normalized(paper.title)
            let titleScore = terms.filter { title.contains($0) }.count * 5
            var best: TextBlock?
            var bestScore = 0
            let published = Set(paper.translatedPages.flatMap(\.blockIDs))
            for block in paper.blocks
            where paper.pageCount > 0
                && ((block.sourcePage >= 0 && block.sourcePage < paper.pageCount)
                    || (block.sourcePage == -1 && (block.richContent != nil || published.contains(block.id))))
            {
                let text = normalized(block.text)
                let score = terms.filter { text.contains($0) }.count
                if score > bestScore {
                    bestScore = score
                    best = block
                }
            }
            guard titleScore + bestScore > 0 else { return nil }
            return AgentSearchHit(
                paperID: paper.id, title: paper.title, blockID: best?.id,
                sourcePage: best.flatMap { $0.sourcePage >= 0 ? $0.sourcePage + 1 : nil },
                excerpt: String((best?.text ?? "").prefix(1_400)),
                score: titleScore + bestScore)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.paperID.uuidString < $1.paperID.uuidString
        }.prefix(limit).map { $0 }
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
