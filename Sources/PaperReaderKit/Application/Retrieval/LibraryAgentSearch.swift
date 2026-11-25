import Foundation

public struct AgentSearchHit: Sendable {
    public var paperID: UUID
    public var title: String
    public var blockID: UUID?
    public var sourcePage: Int?
    public var excerpt: String
    public var score: Int
}

struct AgentPassageIndex: Codable {
    struct Passage: Codable {
        let blockID: UUID?
        let sourcePage: Int?
        let text: String
    }

    var passages: [Passage] = []
    var postings: [String: [Int]] = [:]

    mutating func add(blockID: UUID?, sourcePage: Int?, text: String) {
        let index = passages.count
        passages.append(Passage(blockID: blockID, sourcePage: sourcePage, text: text))
        for word in LibraryAgentSearch.terms(text) { postings[word, default: []].append(index) }
    }
}

/// Normalization and postings are shared across queries for each unchanged paper. Raw blocks remain
/// the citation authority, including version-specific IDs and the original excerpt.
private struct IndexedPaper {
    let title: String
    let foldedTitle: String
    let pageCount: Int
    let blocks: [TextBlock]
    let pages: [PageArtifact]
    let digest: String
    var body = AgentPassageIndex()

    init(_ paper: Paper, root: URL? = nil) throws {
        digest = paper.digest
        title = paper.title
        foldedTitle = LibraryAgentSearch.fold(title)
        pageCount = paper.pageCount
        blocks = paper.blocks
        pages = paper.readingPages
        guard pageCount > 0 else { return }
        let published = Set(pages.flatMap(\.blockIDs))
        for block in blocks {
            try Task.checkCancellation()
            guard
                (0..<pageCount).contains(block.sourcePage)
                    || (block.sourcePage == -1 && (block.richContent != nil || published.contains(block.id)))
            else { continue }
            body.add(blockID: block.id, sourcePage: block.sourcePage >= 0 ? block.sourcePage : nil, text: block.text)
        }
        if body.passages.isEmpty, let root {
            body = try PDFSearchPassages.load(paper, root: root)
        }
    }

    func matches(_ paper: Paper) -> Bool {
        digest == paper.digest && title == paper.title && pageCount == paper.pageCount && blocks == paper.blocks
            && pages == paper.readingPages
    }

    func hit(for id: UUID, terms: Set<String>) throws -> AgentSearchHit? {
        let titleScore = terms.filter { foldedTitle.contains($0) }.count * 5
        var scores: [Int: Int] = [:]
        for term in terms {
            var matches: Set<Int> = []
            for (word, positions) in body.postings {
                try Task.checkCancellation()
                if word.contains(term) { matches.formUnion(positions) }
            }
            for position in matches { scores[position, default: 0] += 1 }
        }
        let best = scores.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }
        guard titleScore > 0 || best != nil else { return nil }
        let block = best.flatMap { body.passages.indices.contains($0.key) ? body.passages[$0.key] : nil }
        return AgentSearchHit(
            paperID: id, title: title, blockID: block?.blockID,
            sourcePage: block?.sourcePage.map { $0 + 1 },
            excerpt: String((block?.text ?? "").prefix(1_400)), score: titleScore + (best?.value ?? 0))
    }
}

public actor LibraryAgentSearchIndex {
    private var entries: [UUID: IndexedPaper] = [:]

    private let root: URL?

    public init(root: URL? = nil) { self.root = root }

    /// Idle prewarming may race with a newer user query. It can only fill a missing entry.
    public func prepareIfAbsent(_ paper: Paper) throws {
        try Task.checkCancellation()
        guard entries[paper.id] == nil else { return }
        let entry = try IndexedPaper(paper, root: root)
        try Task.checkCancellation()
        entries[paper.id] = entry
    }

    public func discard(_ id: UUID) { entries[id] = nil }

    var indexedPaperIDs: Set<UUID> { Set(entries.keys) }

    /// Pass a complete library snapshot. Deletions, edited source text and newly published passages are reconciled.
    public func refresh(_ papers: [Paper]) throws {
        try Task.checkCancellation()
        let live = Set(papers.map(\.id))
        for id in entries.keys where !live.contains(id) { entries[id] = nil }
        for paper in papers {
            try Task.checkCancellation()
            if entries[paper.id]?.matches(paper) != true { entries[paper.id] = try IndexedPaper(paper, root: root) }
        }
    }

    public func search(_ query: String, papers: [Paper], limit: Int = 8) throws -> [AgentSearchHit] {
        let terms = LibraryAgentSearch.terms(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        try refresh(papers)
        return try LibraryAgentSearch.rank(terms, in: entries, limit: limit)
    }
}

public enum LibraryAgentSearch {
    /// One-off lookup retained for callers without a library session.
    public static func search(_ query: String, papers: [Paper], limit: Int = 8) -> [AgentSearchHit] {
        let terms = terms(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var entries: [UUID: IndexedPaper] = [:]
        do {
            for paper in papers { entries[paper.id] = try IndexedPaper(paper) }
            return try rank(terms, in: entries, limit: limit)
        } catch { return [] }
    }

    fileprivate static func rank(_ terms: Set<String>, in entries: [UUID: IndexedPaper], limit: Int) throws
        -> [AgentSearchHit]
    {
        var hits: [AgentSearchHit] = []
        for (id, entry) in entries {
            try Task.checkCancellation()
            if let hit = try entry.hit(for: id, terms: terms) { hits.append(hit) }
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.paperID.uuidString < $1.paperID.uuidString
        }
        return Array(hits.prefix(limit))
    }

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    fileprivate static func terms(_ text: String) -> Set<String> {
        Set(fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
