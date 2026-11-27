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

    func hit(for id: UUID, terms: Set<String>, identifier: String?) throws -> AgentSearchHit? {
        if let identifier {
            let inTitle = !SearchTermMatches.ranges(in: title, query: identifier).isEmpty
            // Restrict literal checks to token posting candidates. A similarly named block
            // from the same paper is not enough to claim a match for a specific identifier.
            let positions = terms.compactMap { body.postings[$0] }.min { $0.count < $1.count } ?? []
            var found: AgentPassageIndex.Passage?
            var excerpt = ""
            for position in positions {
                try Task.checkCancellation()
                let passage = body.passages[position]
                if let match = SearchTermMatches.ranges(in: passage.text, query: identifier).first {
                    let start =
                        passage.text.index(match.lowerBound, offsetBy: -200, limitedBy: passage.text.startIndex)
                        ?? passage.text.startIndex
                    found = passage
                    excerpt = String(passage.text[start...].prefix(1400))
                    break
                }
            }
            guard inTitle || found != nil else { return nil }
            return AgentSearchHit(
                paperID: id, title: title, blockID: found?.blockID,
                sourcePage: found?.sourcePage.map { $0 + 1 }, excerpt: excerpt,
                score: (inTitle ? 5 : 0) + (found == nil ? 0 : 1))
        }
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

    private let fts = LibraryFTSIndex()
    private let semantic: SemanticPassageIndex
    private var passages: [SemanticPassage]?
    private var generation: UInt64 = 0

    public init(
        root: URL? = nil, encoder: (any SemanticTextEncoder)? = nil, minimumScore: Float? = nil
    ) {
        self.root = root
        semantic = SemanticPassageIndex(
            encoder: encoder, cacheURL: root?.appendingPathComponent("DerivedIndexes/vectors.sqlite"),
            namespace: "papers", minimumScore: minimumScore)
    }

    private func corpus() -> [SemanticPassage] {
        if let passages { return passages }
        var result = [SemanticPassage]()
        for id in entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = entries[id] else { continue }
            for (offset, passage) in entry.body.passages.enumerated() {
                result.append(SemanticPassage(sourceID: id, chunk: offset, text: passage.text))
            }
        }
        passages = result
        return result
    }

    public func warmVectors() async throws {
        guard await semantic.isAvailable() else { return }
        try await semantic.prepare(corpus())
    }

    private func changed() {
        passages = nil
        generation &+= 1
    }

    /// Idle prewarming may race with a newer user query. It can only fill a missing entry.
    public func prepareIfAbsent(_ paper: Paper) throws {
        try Task.checkCancellation()
        guard entries[paper.id] == nil else { return }
        let entry = try IndexedPaper(paper, root: root)
        try Task.checkCancellation()
        entries[paper.id] = entry
        fts.replace(
            paperID: paper.id, title: entry.title,
            passages: entry.body.passages.map { ($0.blockID, $0.sourcePage, $0.text) })
        changed()
    }

    public func discard(_ id: UUID) async {
        entries[id] = nil
        fts.remove(paperID: id)
        changed()
        await semantic.removeSources([id])
    }

    var indexedPaperIDs: Set<UUID> { Set(entries.keys) }

    /// Pass a complete library snapshot. Deletions, edited source text and newly published passages are reconciled.
    public func refresh(_ papers: [Paper]) throws {
        try Task.checkCancellation()
        let live = Set(papers.map(\.id))
        for id in entries.keys where !live.contains(id) {
            entries[id] = nil
            fts.remove(paperID: id)
            changed()
        }
        for paper in papers {
            try Task.checkCancellation()
            if entries[paper.id]?.matches(paper) != true {
                let entry = try IndexedPaper(paper, root: root)
                entries[paper.id] = entry
                fts.replace(
                    paperID: paper.id, title: entry.title,
                    passages: entry.body.passages.map { ($0.blockID, $0.sourcePage, $0.text) })
                changed()
            }
        }
    }

    public func search(_ query: String, papers: [Paper], limit: Int = 8) async throws -> [AgentSearchHit] {
        let terms = LibraryAgentSearch.terms(PaperCandidate.queryDOI(query) ?? query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        try refresh(papers)
        let bounded = min(limit, 64)
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = SearchTermMatches.isIdentifierQuery(key) ? key : nil
        let latinTerms = Set(terms.filter { !$0.unicodeScalars.contains { $0.properties.isIdeographic } })
        let cjkTerms = terms.subtracting(latinTerms)
        let lexical: [AgentSearchHit]
        if identifier == nil, fts.isAvailable {
            func toAgentHits(_ hits: [LibraryFTSIndex.Hit]) -> [AgentSearchHit] {
                hits.map { hit in
                    AgentSearchHit(
                        paperID: hit.paperID, title: hit.title, blockID: hit.blockID,
                        sourcePage: hit.sourcePage, excerpt: hit.excerpt, score: hit.score)
                }
            }
            var combined: [UUID: AgentSearchHit] = [:]
            func merge(_ incoming: [AgentSearchHit]) {
                for hit in incoming {
                    if let existing = combined[hit.paperID] {
                        let prefersIncoming =
                            hit.score > existing.score
                            || (existing.blockID == nil && existing.sourcePage == nil
                                && (hit.blockID != nil || hit.sourcePage != nil))
                        var merged = prefersIncoming ? hit : existing
                        merged.score = max(existing.score, hit.score) + min(existing.score, hit.score) / 2
                        combined[hit.paperID] = merged
                    } else {
                        combined[hit.paperID] = hit
                    }
                }
            }
            if !latinTerms.isEmpty {
                let strictLatin = toAgentHits(fts.search(terms: latinTerms, requireAllTerms: true, limit: bounded * 2))
                if !strictLatin.isEmpty {
                    merge(strictLatin)
                } else {
                    let exactFallback = try LibraryAgentSearch.rank(
                        latinTerms, in: entries, limit: bounded * 2, identifier: nil)
                    merge(
                        exactFallback.isEmpty
                            ? toAgentHits(fts.search(terms: latinTerms, requireAllTerms: false, limit: bounded * 2))
                            : exactFallback)
                }
            }
            if !cjkTerms.isEmpty {
                let trigramHits = toAgentHits(
                    fts.searchTrigram(terms: cjkTerms, requireAllTerms: false, limit: bounded * 2))
                merge(trigramHits)
                let shortCJK = cjkTerms.filter { $0.count < 3 }
                if !shortCJK.isEmpty || trigramHits.isEmpty {
                    merge(try LibraryAgentSearch.rank(cjkTerms, in: entries, limit: bounded * 2, identifier: nil))
                }
            }
            lexical = combined.values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.paperID.uuidString < $1.paperID.uuidString
            }.prefix(bounded * 2).map { $0 }
        } else {
            lexical = try LibraryAgentSearch.rank(terms, in: entries, limit: bounded * 2, identifier: identifier)
        }
        let revision = generation
        guard identifier == nil, await semantic.isAvailable() else {
            guard revision == generation else { throw CancellationError() }
            return Array(lexical.prefix(bounded))
        }
        guard revision == generation else { throw CancellationError() }
        let hits = try await semantic.matches(query, passages: corpus(), allowed: Set(entries.keys), limit: bounded * 2)
        guard revision == generation else { throw CancellationError() }
        var byID = Dictionary(uniqueKeysWithValues: lexical.map { ($0.paperID, $0) })
        for hit in hits {
            let key = hit.passage
            guard let entry = entries[key.sourceID], entry.body.passages.indices.contains(key.chunk) else { continue }
            let passage = entry.body.passages[key.chunk]
            if let old = byID[key.sourceID], old.blockID != nil || old.sourcePage != nil { continue }
            byID[key.sourceID] = AgentSearchHit(
                paperID: key.sourceID, title: entry.title, blockID: passage.blockID,
                sourcePage: passage.sourcePage.map { $0 + 1 }, excerpt: String(passage.text.prefix(1400)),
                score: byID[key.sourceID]?.score ?? 1)
        }
        return SemanticPassageIndex.fused(lexical: lexical.map(\.paperID), semantic: hits.map(\.passage.sourceID))
            .prefix(bounded).compactMap { byID[$0] }
    }
}

public enum LibraryAgentSearch {
    /// One-off lookup retained for callers without a library session.
    public static func search(_ query: String, papers: [Paper], limit: Int = 8) -> [AgentSearchHit] {
        let terms = terms(PaperCandidate.queryDOI(query) ?? query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var entries: [UUID: IndexedPaper] = [:]
        do {
            for paper in papers { entries[paper.id] = try IndexedPaper(paper) }
            let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return try rank(
                terms, in: entries, limit: limit, identifier: SearchTermMatches.isIdentifierQuery(key) ? key : nil)
        } catch { return [] }
    }

    fileprivate static func rank(
        _ terms: Set<String>, in entries: [UUID: IndexedPaper], limit: Int, identifier: String?
    ) throws
        -> [AgentSearchHit]
    {
        var hits: [AgentSearchHit] = []
        for (id, entry) in entries {
            try Task.checkCancellation()
            if let hit = try entry.hit(for: id, terms: terms, identifier: identifier) { hits.append(hit) }
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
