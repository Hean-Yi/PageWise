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

    public init() {}

    public func search(
        query: String, notes: [ReadingNote], paperTitles: [UUID: String], excluding: UUID? = nil,
        paperID: UUID? = nil, limit: Int = 6
    ) throws -> [Evidence] {
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
            let chunks = Self.chunks(from: Self.searchableBody(note.markdown))
            let titleTerms = Self.terms(in: title)
            let terms = chunks.reduce(into: titleTerms) { $0.formUnion($1.terms) }
            entries[note.id] = Entry(
                paperID: note.paperID, title: title, markdown: note.markdown, titleTerms: titleTerms,
                chunks: chunks, terms: terms)
            for term in terms { postings[term, default: []].insert(note.id) }
        }
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let terms = Self.terms(in: String(query.prefix(4_000)))
        let browsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var weights: [String: Double] = [:]
        var candidates = Set<UUID>()
        for term in terms {
            guard let matches = postings[term] else { continue }
            weights[term] = log(1 + Double(entries.count) / Double(matches.count))
            candidates.formUnion(matches)
        }
        func weight(_ terms: Set<String>) -> Double {
            if terms.count < weights.count { return terms.reduce(0) { $0 + (weights[$1] ?? 0) } }
            return weights.reduce(0) { $0 + (terms.contains($1.key) ? $1.value : 0) }
        }
        var results: [(evidence: Evidence, score: Double, modified: Date)] = []
        for note in active where note.paperID != excluding && (paperID == nil || note.paperID == paperID) {
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
            let hit = Evidence(
                id: note.id.uuidString, title: entry.title, text: best.text,
                paperID: note.paperID, sourcePage: note.anchors.first?.readingPageIndex, readingNoteID: note.id)
            results.append((hit, bodyScore + 0.55 * weight(entry.titleTerms), note.modifiedAt))
        }
        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.evidence.id < $1.evidence.id
        }.prefix(min(limit, 64)).map(\.evidence)
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
        for term in entry.terms {
            postings[term]?.remove(id)
            if postings[term]?.isEmpty == true { postings[term] = nil }
        }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "are", "as", "and", "the", "of", "at", "to", "on", "in", "for", "with", "is", "or", "was", "were",
        "it",
        "that", "this", "paper", "papers", "note", "notes", "my", "find", "about", "using",
        "的", "了", "和", "在", "是", "我", "这", "中", "有", "对", "一个", "论文", "笔记", "查找", "精读", "引用",
    ]

    private static func terms(in text: String) -> Set<String> {
        Retriever.tokens(text).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) && !stopWords.contains($0) }
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
