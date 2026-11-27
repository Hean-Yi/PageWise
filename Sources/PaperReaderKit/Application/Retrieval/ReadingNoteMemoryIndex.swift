import Foundation

/// A rebuildable, device-local inverted index over the bookcase's saved reading notes.
/// The paper text and the anchor text are never indexed as a reader's observation.
public actor ReadingNoteMemoryIndex {
    private struct Chunk {
        let text: String
        let terms: Set<String>
    }

    private struct Entry {
        let paperID: UUID
        let title: String
        let markdown: String
        let titleTerms: Set<String>
        let chunks: [Chunk]
        let terms: Set<String>
    }

    private var entries: [UUID: Entry] = [:]
    private var postings: [String: Set<UUID>] = [:]
    private var cachedCorpus: (excluding: Set<UUID>, passages: [SemanticPassage])?

    private let semantic: SemanticPassageIndex
    private let usesVectors: Bool

    public init(
        encoder: (any SemanticTextEncoder)? = nil, cacheURL: URL? = nil, namespace: String = "notes",
        minimumScore: Float? = nil
    ) {
        semantic = SemanticPassageIndex(
            encoder: encoder, cacheURL: cacheURL, namespace: namespace, minimumScore: minimumScore)
        usesVectors = encoder != nil
    }

    /// True once the semantic vectors are ready. The first search returns lexical results while
    /// this is false; callers never need to wait for a cold model before showing something.
    public func isSemanticWarm() async -> Bool {
        await semantic.isWarm()
    }

    /// Idle prewarm. A missing model or an empty corpus is a no-op.
    public func warm(notes: [ReadingNote], paperTitles: [UUID: String]) async {
        _ = try? await search(
            query: "", notes: notes, paperTitles: paperTitles, limit: 0, mode: .hybrid)
    }

    public func search(
        query: String, state: LibraryState, pending: Set<UUID>, excluding: UUID?, paperID: UUID?,
        shelfID: UUID? = nil, limit: Int, includeArchived: Bool, mode: RetrievalMode = .hybrid
    ) async throws -> [Evidence] {
        let withdrawn = ChatSourceVersions.withdrawnNoteIDs(in: state, excluding: pending)
        let unavailable: Set<UUID> = includeArchived ? [] : withdrawn
        let titles = Dictionary(
            state.papers.lazy.filter { !pending.contains($0.id) }.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
        let allowedPaperIDs: Set<UUID>? = shelfID.map { shelf in
            Set(
                state.papers.lazy
                    .filter { !pending.contains($0.id) && state.paperShelfIDs[$0.id.uuidString] == shelf }
                    .map(\.id))
        }
        return try await search(
            query: query, notes: state.readingNotes, paperTitles: titles, excluding: excluding, paperID: paperID,
            allowedPaperIDs: allowedPaperIDs, limit: limit, unavailable: unavailable, mode: mode, withdrawn: withdrawn)
    }

    public func search(
        query: String, notes: [ReadingNote], paperTitles: [UUID: String], excluding: UUID? = nil,
        paperID: UUID? = nil, allowedPaperIDs: Set<UUID>? = nil, limit: Int = 6, unavailable: Set<UUID> = [],
        mode: RetrievalMode = .hybrid, withdrawn: Set<UUID> = []
    ) async throws -> [Evidence] {
        let hasModel = usesVectors && mode != .lexical ? await semantic.isAvailable() : false
        let active = notes.filter { $0.deletedAt == nil && paperTitles[$0.paperID] != nil }
        let liveIDs = Set(active.map(\.id))
        for id in Set(entries.keys).subtracting(liveIDs) { remove(id) }
        for note in active {
            try Task.checkCancellation()
            guard let title = paperTitles[note.paperID] else { continue }
            if let cached = entries[note.id], cached.markdown == note.markdown, cached.title == title,
                cached.paperID == note.paperID
            {
                continue
            }
            remove(note.id)
            cachedCorpus = nil
            let chunks = Self.chunks(from: Self.searchableBody(note.markdown))
            let titleTerms = Self.terms(in: title)
            let terms = chunks.reduce(into: titleTerms) { $0.formUnion($1.terms) }
            entries[note.id] = Entry(
                paperID: note.paperID, title: title, markdown: note.markdown, titleTerms: titleTerms,
                chunks: chunks, terms: terms)
            for term in terms { postings[term, default: []].insert(note.id) }
        }
        try Task.checkCancellation()
        let semanticPassages: [SemanticPassage]
        if hasModel {
            let excluded = unavailable.union(withdrawn)
            if let cachedCorpus, cachedCorpus.excluding == excluded {
                semanticPassages = cachedCorpus.passages
            } else {
                semanticPassages = active.filter { !excluded.contains($0.id) }.flatMap { note in
                    (entries[note.id]?.chunks ?? []).enumerated().map { position, chunk in
                        SemanticPassage(sourceID: note.id, chunk: position, text: chunk.text)
                    }
                }
                cachedCorpus = (excluded, semanticPassages)
            }
        } else {
            semanticPassages = []
        }
        guard limit > 0 else {
            if hasModel { try await semantic.prepare(semanticPassages) }
            return []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = mode != .semantic && SearchTermMatches.isIdentifierQuery(trimmed)
        let terms = Self.terms(in: String(query.prefix(4_000)))
        let browsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var weights: [String: Double] = [:]
        var candidates = Set<UUID>()
        let eligibleCount = unavailable.isEmpty ? liveIDs.count : liveIDs.subtracting(unavailable).count
        for term in terms {
            guard let indexed = postings[term] else { continue }
            let matches = unavailable.isEmpty ? indexed : indexed.subtracting(unavailable)
            guard !matches.isEmpty else { continue }
            let idf = log(1 + Double(eligibleCount) / Double(matches.count))
            weights[term] = term.hasPrefix("concept:") || term.hasPrefix("phrase:") ? idf * 1.8 : idf
            candidates.formUnion(matches)
        }
        func weight(_ terms: Set<String>) -> Double {
            if terms.count < weights.count { return terms.reduce(0) { $0 + (weights[$1] ?? 0) } }
            return weights.reduce(0) { $0 + (terms.contains($1.key) ? $1.value : 0) }
        }
        var results: [(evidence: Evidence, score: Double, modified: Date)] = []
        for note in active
        where !unavailable.contains(note.id) && note.paperID != excluding && (paperID == nil || note.paperID == paperID)
            && (allowedPaperIDs?.contains(note.paperID) ?? true)
        {
            guard browsing || candidates.contains(note.id), let entry = entries[note.id],
                let first = entry.chunks.first
            else { continue }
            var best = first
            var bodyScore = weight(first.terms)
            for chunk in entry.chunks.dropFirst() {
                let score = weight(chunk.terms)
                if score > bodyScore {
                    best = chunk
                    bodyScore = score
                }
            }
            if identifier {
                if let exact = entry.chunks.first(where: {
                    !SearchTermMatches.ranges(in: $0.text, query: trimmed).isEmpty
                }) {
                    best = exact
                } else if SearchTermMatches.ranges(in: entry.title, query: trimmed).isEmpty {
                    continue
                }
            }
            let hit = Evidence(
                id: note.id.uuidString, title: entry.title, text: best.text,
                paperID: note.paperID, sourcePage: note.anchors.first?.readingPageIndex, readingNoteID: note.id)
            results.append((hit, bodyScore + 0.55 * weight(entry.titleTerms), note.modifiedAt))
        }
        let lexical = results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.evidence.id < $1.evidence.id
        }.prefix(64).map(\.evidence)
        guard !browsing, !identifier, mode != .lexical, hasModel else {
            return mode == .semantic && !browsing ? [] : Array(lexical.prefix(limit))
        }
        let eligible = active.filter {
            !unavailable.contains($0.id) && $0.paperID != excluding && (paperID == nil || $0.paperID == paperID)
                && (allowedPaperIDs?.contains($0.paperID) ?? true)
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let matches = try await semantic.matches(query, passages: semanticPassages, allowed: Set(byID.keys), limit: 64)
        let semanticIDs = matches.map(\.passage.sourceID)
        // In a full question, a single shared word is weak corroboration. Preserve full
        // reciprocal-rank weight for short lookups and multiple matching terms.
        var lexicalSupport: [UUID: Double] = [:]
        if !semanticIDs.isEmpty && mode == .hybrid && terms.count > 2 {
            for hit in lexical {
                guard let id = hit.readingNoteID, let entry = entries[id] else { continue }
                if terms.intersection(entry.terms).count == 1 {
                    lexicalSupport[id] = 1 / Double(terms.count)
                }
            }
        }
        let ordered =
            mode == .semantic
            ? semanticIDs
            : SemanticPassageIndex.fused(
                lexical: lexical.compactMap(\.readingNoteID), semantic: semanticIDs, lexicalSupport: lexicalSupport)
        var evidence = Dictionary(
            uniqueKeysWithValues: lexical.compactMap { hit in hit.readingNoteID.map { ($0, hit) } })
        for match in matches {
            let p = match.passage
            guard let note = byID[p.sourceID], let title = paperTitles[note.paperID] else { continue }
            // Preserve an exact match in the source text. A title-only hit can use a better semantic excerpt.
            if mode != .semantic, let hit = evidence[p.sourceID], !Self.terms(in: hit.text).isDisjoint(with: terms) {
                continue
            }
            evidence[p.sourceID] = Evidence(
                id: p.sourceID.uuidString, title: title, text: p.text, paperID: note.paperID,
                sourcePage: note.anchors.first?.readingPageIndex, readingNoteID: p.sourceID)
        }
        return ordered.prefix(min(limit, 64)).compactMap { evidence[$0] }
    }

    // Generated labels can contain excerpts of other notes. Indexing those labels would
    // preserve a deleted idea under every note that links to it. Keep only surrounding prose.
    private static let localLink = try! NSRegularExpression(
        pattern: #"(?i)!?\[(?:\\.|[^\[\]\\]|\[(?:\\.|[^\[\]\\])*\])*\]\(\s*<?paperreader://passage/[0-9a-f-]+>?\s*\)"#)

    public nonisolated static func searchableBody(_ markdown: String) -> String {
        localLink.stringByReplacingMatches(
            in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: " "
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remove(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        cachedCorpus = nil
        for term in entry.terms {
            postings[term]?.remove(id)
            if postings[term]?.isEmpty == true { postings[term] = nil }
        }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "are", "as", "and", "the", "of", "at", "to", "on", "in", "for", "with", "is", "or", "was", "were",
        "it",
        "that", "this", "paper", "papers", "note", "notes", "my", "find", "about", "using",
        "what", "which", "how", "who", "does", "do", "did",
        "的", "了", "和", "在", "是", "会", "吗", "呢", "怎么", "如何", "我", "这", "中", "有", "对", "一个", "论文", "笔记", "查找", "精读", "引用",
    ]

    private static func terms(in text: String) -> Set<String> {
        Retriever.expandedTokens(text).filter {
            $0.contains(where: { $0.isLetter || $0.isNumber }) && !stopWords.contains($0)
        }
    }

    /// Chunk long Markdown so an observation near the end of a note remains citable verbatim.
    private static func chunks(from text: String) -> [Chunk] {
        var rest = text[...]
        var result: [Chunk] = []
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: 900, limitedBy: rest.endIndex) ?? rest.endIndex
            if end != rest.endIndex {
                let lower = rest.index(end, offsetBy: -230)
                if let boundary = rest[lower..<end].lastIndex(where: { $0.isWhitespace || "。！？".contains($0) }) {
                    end = rest.index(after: boundary)
                }
            }
            let snippet = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty { result.append(Chunk(text: snippet, terms: terms(in: snippet))) }
            rest = rest[end...]
        }
        return result
    }
}
