import CryptoKit
import Foundation

/// All source prose stays in the library. The checkpoint contains bibliographic terms and paper IDs.
/// Counts are of independent papers. A word that occurs in only one title never creates a research topic.
public actor ResearchBriefIndex {
    private struct Entry: Codable, Equatable {
        let titleHash: Data
        let words: Set<String>
    }
    private struct Group: Codable, Equatable {
        let shelf: UUID?
        let terms: [String]
        let ids: [UUID]
    }
    private struct Catalog: Codable, Equatable {
        let format: Int
        let terms: [UUID: Entry]
        let groups: [Group]
        let noted: Set<UUID>
        let discussed: Set<UUID>
    }

    private let store: LibraryStore
    private var titles: [UUID: Entry] = [:]
    private var inputs: BriefInputs?
    private var current: Catalog?
    private var published: Catalog?
    private var publishedPayload: Data?
    private var opened = false
    private var publishedRevision: Int64 = -1

    public init(store: LibraryStore) { self.store = store }

    /// Incremental entry point. The event log identifies changed sources, while the source
    /// generation catches revisions that changed back to an earlier wording. A bounded lease
    /// keeps two windows from rebuilding and publishing the same index concurrently.
    @discardableResult
    public func maintain(
        audit: Bool = false, warming notes: ReadingNoteMemoryIndex? = nil, memories: ResearchMemory? = nil
    ) async throws -> Bool {
        let owner = UUID()
        guard try await store.acquireResearchLease(owner: owner) else { return false }
        do {
            try await maintainHoldingLease(audit: audit, warming: notes, memories: memories)
            try await store.releaseResearchLease(owner: owner)
            return true
        } catch {
            try? await store.releaseResearchLease(owner: owner)
            throw error
        }
    }

    /// A bounded pass may leave older rows behind. The foreground worker uses this to continue
    /// immediately instead of waiting for the next scheduled audit.
    public func hasPendingResearchEvents() async -> Bool {
        guard let pending = try? await store.pendingResearchEvents(limit: 1) else { return false }
        return !pending.isEmpty
    }

    private func maintainHoldingLease(
        audit: Bool, warming notes: ReadingNoteMemoryIndex?, memories: ResearchMemory?
    ) async throws {
        if audit { opened = false }
        try await open()
        guard let snapshot = try await store.researchMaintenanceSnapshot() else { return }
        let needsAudit = audit || snapshot.indexState == nil || published == nil
        let generationChanged = snapshot.indexState?.lastResearchRevision != snapshot.researchRevision
        // Warming is independent of whether the bibliographic catalog itself changed. A launch
        // with no pending events still needs the note postings and optional memory vectors ready
        // before the first question, especially after a derived vector cache was removed.
        if let notes {
            // The existing note actor reconciles tokens and postings before applying its result limit.
            _ = try await notes.search(
                query: "", state: snapshot.state, pending: [], excluding: nil, paperID: nil, limit: 0,
                includeArchived: false)
        }
        try await memories?.prepare(snapshot.state)
        guard needsAudit || generationChanged || !snapshot.pendingEvents.isEmpty else { return }
        let catalog = try resolve(BriefInputs(snapshot.state, excluding: []))
        let data: Data
        if catalog == published, let payload = publishedPayload {
            data = payload
        } else {
            data = try JSONEncoder().encode(catalog)
        }
        let lastSequence = snapshot.pendingEvents.last?.sequence ?? snapshot.indexState?.lastEventSequence ?? 0
        try Task.checkCancellation()
        guard
            try await store.publishResearchIndex(
                data, previousPayload: publishedPayload, libraryRevision: snapshot.libraryRevision,
                researchRevision: snapshot.researchRevision, lastEventSequence: lastSequence, auditedAt: Date())
        else {
            throw ReaderError.message("研究简报尚未写入，将在下一次维护时重试。")
        }
        if snapshot.libraryRevision >= publishedRevision {
            published = catalog
            publishedPayload = data
            publishedRevision = snapshot.libraryRevision
        }
    }

    public func brief(
        matching query: String?, limit: Int, state: LibraryState, excluding pending: Set<UUID>,
        noteHits: [Evidence], noteHitsQuery: String? = nil
    ) async throws -> ResearchBrief {
        try await open()
        let basis = BriefInputs(state, excluding: pending)
        let index = try resolve(basis)
        let broad = query == nil || query == "*"
        let terms = broad ? Set<String>() : Self.words(String((query ?? "").prefix(512)))
        // A returned chunk must still match a live note, even when the index was read before an edit.
        let annotated = noteHits.isEmpty ? [] : Set(state.chats.flatMap { $0.closeReadingNoteIDs ?? [] })
        let authored = noteHits.isEmpty ? [] : Set(state.chats.compactMap(\.readingNoteID))
        var hitByPaper: [UUID: (ReadingNote, String, Int)] = [:]
        if query != nil && !noteHits.isEmpty {
            let candidates = Set(noteHits.prefix(32).compactMap(\.readingNoteID))
            let notes = Dictionary(
                state.readingNotes.lazy.filter { candidates.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            for (rank, hit) in noteHits.prefix(32).enumerated() {
                guard let id = hit.readingNoteID, let stored = notes[id], stored.deletedAt == nil,
                    stored.paperID == hit.paperID, basis.papers[stored.paperID] != nil,
                    hitByPaper[stored.paperID] == nil,
                    let note = ChatSourceVersions.recalledNote(stored, in: state, excluding: pending),
                    !hit.text.isEmpty, ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(hit.text),
                    let excerpt = Self.excerpt(hit.text, matching: broad ? nil : terms)
                        ?? (noteHitsQuery == query ? String(hit.text.prefix(180)) : nil)
                else { continue }
                hitByPaper[note.paperID] = (note, excerpt, rank)
            }
        }
        struct Ranked {
            let group: Group
            let label: String
            let kind: String
            let score: Int
        }
        var sourceScores: [UUID: Int] = [:]
        var matching = Set<UUID>()
        for (id, entry) in index.terms {
            let overlap = broad ? 0 : entry.words.intersection(terms).count
            if overlap > 0 || hitByPaper[id] != nil { matching.insert(id) }
            sourceScores[id] =
                hitByPaper[id].map { 1000 - $0.2 }
                ?? (overlap * 10 + (basis.noted.contains(id) ? 2 : 0) + (basis.discussed.contains(id) ? 1 : 0))
        }
        var ranked: [Ranked] = []
        for group in index.groups {
            try Task.checkCancellation()
            let label =
                group.shelf.flatMap { basis.shelves[$0] }
                ?? (group.terms.isEmpty ? "未分类论文" : group.terms.joined(separator: " / "))
            let matchingLabel =
                broad ? 0 : (group.terms.isEmpty ? Self.words(label) : Set(group.terms)).intersection(terms).count
            let matchingPapers = broad ? 0 : group.ids.filter(matching.contains).count
            guard broad || matchingLabel > 0 || matchingPapers > 0 else { continue }
            let engaged = group.ids.reduce(0) {
                $0 + (basis.noted.contains($1) ? 2 : 0) + (basis.discussed.contains($1) ? 1 : 0)
            }
            let priority = group.shelf != nil ? 2 : group.terms.isEmpty ? 0 : 1
            let score = matchingLabel * 10_000 + min(matchingPapers, 30) * 100 + min(engaged, 30) * 3 + priority
            let kind = group.shelf != nil ? "shelf" : group.terms.isEmpty ? "unfiled" : "recurring_title_terms"
            ranked.append(Ranked(group: group, label: label, kind: kind, score: score))
        }
        if !broad, let query, hitByPaper.count > 1 {
            // This explicitly scoped topic can join notes from papers with unrelated titles and shelves.
            let group = Group(shelf: nil, terms: [], ids: hitByPaper.keys.sorted { $0.uuidString < $1.uuidString })
            ranked.insert(
                Ranked(group: group, label: String(query.prefix(80)), kind: "matching_note_passages", score: Int.max),
                at: 0)
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.group.ids.count != $1.group.ids.count { return $0.group.ids.count > $1.group.ids.count }
            if $0.label != $1.label { return $0.label < $1.label }
            return ($0.group.shelf?.uuidString ?? "") < ($1.group.shelf?.uuidString ?? "")
        }
        var versions = ChatSourceVersions()
        let topics = ranked.prefix(max(0, min(8, limit))).map { candidate in
            let group = candidate.group
            let ordered = group.ids.sorted {
                let lhs = sourceScores[$0] ?? 0
                let rhs = sourceScores[$1] ?? 0
                return lhs == rhs ? $0.uuidString < $1.uuidString : lhs > rhs
            }
            let sources = ordered.prefix(3).compactMap { id -> ResearchBrief.Source? in
                guard let paper = basis.papers[id] else { return nil }
                let hit = hitByPaper[id]
                let origin = hit.map { hit in
                    annotated.contains(hit.0.id) || (hit.0.isDocumentSummary && authored.contains(hit.0.id))
                        ? "aiCloseReading"
                        : (authored.contains(hit.0.id) || hit.0.backgroundSources != nil) ? "aiDiscussion" : "localNote"
                }
                if let note = hit?.0 { versions.include(note) }
                return .init(
                    paperID: id, title: String(PaperTitle.display(paper.title).prefix(240)),
                    noteID: hit?.0.id, excerpt: hit?.1, noteOrigin: origin)
            }
            return ResearchBrief.Topic(
                label: candidate.label,
                basis: candidate.kind,
                paperCount: group.ids.count, notedPapers: group.ids.filter(basis.noted.contains).count,
                discussedPapers: group.ids.filter(basis.discussed.contains).count, sources: sources)
        }
        return ResearchBrief(topics: topics, inputs: basis, versions: versions)
    }

    private func open() async throws {
        guard !opened else { return }
        let data = try? await store.readResearchCheckpoint()
        try Task.checkCancellation()
        guard !opened else { return }
        opened = true
        published = nil
        publishedPayload = nil
        if let data, let saved = try? JSONDecoder().decode(Catalog.self, from: data), saved.format == 1 {
            // Reconcile all memberships with live sources before using a cache, including after restoration.
            titles = saved.terms
            published = saved
            publishedPayload = data
        }
    }

    private func resolve(_ next: BriefInputs) throws -> Catalog {
        if let current, inputs == next { return current }
        var nextTitles: [UUID: Entry] = [:]
        var shelves: [UUID: [UUID]] = [:]
        var unfiled: [UUID] = []
        var occurrences: [String: [UUID]] = [:]
        for (id, paper) in next.papers {
            try Task.checkCancellation()
            let text = String(PaperTitle.display(paper.title).prefix(512))
            let hash = Data(SHA256.hash(data: Data(text.utf8)))
            let entry =
                titles[id].flatMap { $0.titleHash == hash ? $0 : nil }
                ?? Entry(titleHash: hash, words: Set(Self.words(text).sorted().prefix(48)))
            nextTitles[id] = entry
            if let shelf = paper.shelf, next.shelves[shelf] != nil {
                shelves[shelf, default: []].append(id)
            } else {
                unfiled.append(id)
            }
            for word in entry.words { occurrences[word, default: []].append(id) }
        }
        func ordered(_ values: [UUID]) -> [UUID] { values.sorted { $0.uuidString < $1.uuidString } }
        var groups = shelves.map { Group(shelf: $0.key, terms: [], ids: ordered($0.value)) }
            .sorted { ($0.shelf?.uuidString ?? "") < ($1.shelf?.uuidString ?? "") }
        if !unfiled.isEmpty { groups.append(Group(shelf: nil, terms: [], ids: ordered(unfiled))) }
        var shared: [[UUID]: [String]] = [:]
        for (word, ids) in occurrences where ids.count > 1 { shared[ordered(ids), default: []].append(word) }
        let recurring = shared.map { Group(shelf: nil, terms: Array($0.value.sorted().prefix(3)), ids: $0.key) }
        groups += recurring.sorted { $0.terms.lexicographicallyPrecedes($1.terms) }
        let result = Catalog(format: 1, terms: nextTitles, groups: groups, noted: next.noted, discussed: next.discussed)
        current = result
        inputs = next
        titles = nextTitles
        return result
    }

    private static func excerpt(_ text: String, matching terms: Set<String>?) -> String? {
        guard let terms else { return String(text.prefix(180)) }
        let matches = words(text).intersection(terms).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        guard let term = matches.first,
            let range = text.range(of: term, options: [.caseInsensitive, .widthInsensitive])
        else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(180))
    }

    private static func words(_ text: String) -> Set<String> {
        Retriever.tokens(text).filter { $0.count >= 2 && $0.contains(where: \.isLetter) && !stopWords.contains($0) }
    }
    private static let stopWords: Set<String> = [
        "for", "in", "an", "the", "by", "from", "with", "of", "on", "to", "as", "and", "is", "are", "at", "via",
        "toward", "towards", "how", "using", "study", "studies", "based", "paper", "论文", "研究", "通过", "基于", "方法",
    ]
}
