import Foundation

/// A live projection of local records. Each paper counts once on its current shelf.
public struct ResearchOverview: Equatable, Sendable, Encodable {
    public struct Topic: Equatable, Sendable, Encodable {
        public let shelf: String
        public var papers = 0
        public var papersWithNotes = 0
        public var papersWithDiscussions = 0
    }

    public let paperCount: Int
    public let unfiledCount: Int
    public let shelfCount: Int
    public let topics: [Topic]

    public init(state: LibraryState, excluding pending: Set<UUID> = []) {
        let noted = Set(state.readingNotes.lazy.filter { $0.deletedAt == nil }.map(\.paperID))
        let discussed = Set(state.chats.lazy.filter { $0.closeReadingVersion == nil }.map(\.paperID))
        var groups = Dictionary(uniqueKeysWithValues: state.shelves.map { ($0.id, Topic(shelf: $0.name)) })
        var total = 0
        var unfiled = 0
        for paper in state.papers where !pending.contains(paper.id) {
            total += 1
            if let id = state.paperShelfIDs[paper.id.uuidString], groups[id] != nil {
                groups[id]?.papers += 1
                if noted.contains(paper.id) { groups[id]?.papersWithNotes += 1 }
                if discussed.contains(paper.id) { groups[id]?.papersWithDiscussions += 1 }
            } else {
                unfiled += 1
            }
        }
        let occupied = groups.values.filter { $0.papers > 0 }
        paperCount = total
        unfiledCount = unfiled
        shelfCount = occupied.count
        topics = Array(
            occupied.sorted {
                if $0.papersWithNotes != $1.papersWithNotes { return $0.papersWithNotes > $1.papersWithNotes }
                if $0.papersWithDiscussions != $1.papersWithDiscussions {
                    return $0.papersWithDiscussions > $1.papersWithDiscussions
                }
                if $0.papers != $1.papers { return $0.papers > $1.papers }
                return $0.shelf < $1.shelf
            }.prefix(12))
    }
}

public actor ResearchMemory {
    private var indexedTerms: [UUID: (text: String, words: Set<String>)] = [:]

    private let semantic: SemanticPassageIndex
    private let usesVectors: Bool

    public init(encoder: (any SemanticTextEncoder)? = nil, cacheURL: URL? = nil, minimumScore: Float? = nil) {
        semantic = SemanticPassageIndex(encoder: encoder, cacheURL: cacheURL, minimumScore: minimumScore)
        usesVectors = encoder != nil
    }

    public static func permitsAutomaticWrite(for message: String) -> Bool {
        let denied =
            #"(?i)(?:不要|不用|别|不必|无需|不许|禁止|暂不|不想).{0,10}(?:记|记录|保存|存储|留存)|(?:删除|撤回|清除|忘掉|忘记).{0,12}(?:记忆|记录|这段|这句|我刚)|(?:don['’]t|do not|never|without)\s+(?:ever\s+)?(?:save|remember|store|retain|record|write.{0,24}memory)|(?:forget|erase|withdraw)\s+(?:this|that|my)|off the record"#
        return message.range(of: denied, options: .regularExpression) == nil
    }

    /// Deferring an annotation leaves the discussion available for a later reader-authorized note.
    /// Any separate non-retention request in the same turn continues to exclude it from replay.
    public static func permitsConversationHistory(for message: String) -> Bool {
        if permitsAutomaticWrite(for: message) { return true }
        let noteVeto =
            #"(?i)(?:不要|不用|别|不必|无需|暂不|不想)(?:现在|先|再|帮我|给我|直接|实际|自动)*(?:记|做|写|记录|保存|添加|生成)(?:一条|这条|一份|我的)?(?:阅读|论文|页内|页边)?笔记(?:了|吧)?(?=$|[\s，,。；;.!！?？])|(?:don['’]t|do not|never)\s+(?:write|make|save|create|take|record)\s+(?:(?:a|any|the|reading|paper)\s+)*notes?\s*(?:yet|for now)?(?=$|[,.!?;])"#
        let remaining = message.replacingOccurrences(of: noteVeto, with: "。", options: .regularExpression)
        return remaining != message && permitsAutomaticWrite(for: remaining)
    }

    /// Compare the extracted proposition independently of a question's wording or source.
    /// Repeated source questions also protect older corrections and tombstones.
    public static func candidate(_ raw: String, turn: ChatTurn, state: LibraryState) -> MemoryItem? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard permitsAutomaticWrite(for: turn.question), !value.isEmpty, value.count <= 200 else { return nil }
        let candidate = MemoryItem(text: MemoryItem.automaticPrefix + value, sourceID: turn.id)
        guard let fingerprint = candidate.originalFingerprint, !state.suppressedMemoryFingerprints.contains(fingerprint)
        else { return nil }
        let key = normalized(turn.question)
        let earlier = Set(
            state.chats.lazy.filter { $0.paperID == turn.paperID && normalized($0.question) == key }.map(\.id))
        guard
            !state.memories.contains(where: {
                $0.sourceID == turn.id || (($0.deleted || $0.userEdited) && earlier.contains($0.sourceID))
                    || $0.suppressesAutomaticProposition(fingerprint)
            })
        else { return nil }
        return candidate
    }

    public func relevant(to query: String, paperID: UUID? = nil, state: LibraryState, excluding pending: Set<UUID> = [])
        async throws -> [MemoryItem]
    {
        let hasModel = usesVectors ? await semantic.isAvailable() : false
        try Task.checkCancellation()
        let active = state.memories.filter { !$0.deleted && !$0.text.isEmpty && !$0.isResponsePreference }
        let live = Set(active.map(\.id))
        for id in indexedTerms.keys where !live.contains(id) { indexedTerms[id] = nil }
        let words = Retriever.tokens(String(query.prefix(1_000))).subtracting(Self.stopWords)
        let broad = paperID == nil && query == "*"
        guard !words.isEmpty || broad else { return [] }
        let origins = ResearchMemoryOrigins(state: state, excluding: pending)
        var passages: [SemanticPassage] = []
        var matches: [(item: MemoryItem, score: Int)] = []
        for memory in active {
            try Task.checkCancellation()
            guard let origin = origins.resolve(memory) else { continue }
            if hasModel {
                passages.append(Self.passage(memory))
            }
            if broad {
                matches.append((memory, memory.userEdited ? 1 : 0))
                continue
            }
            let text = String(memory.text.prefix(400))
            let terms: Set<String>
            if let entry = indexedTerms[memory.id], entry.text == text {
                terms = entry.words
            } else {
                terms = Retriever.tokens(text)
                indexedTerms[memory.id] = (text, terms)
            }
            let overlap = terms.intersection(words).count
            guard overlap > 0 else { continue }
            matches.append(
                (
                    memory,
                    overlap * 4 + (memory.userEdited ? 2 : 0) + (paperID.map { origin == .paper($0) } == true ? 1 : 0)
                ))
        }
        let lexical = matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.createdAt != $1.item.createdAt { return $0.item.createdAt > $1.item.createdAt }
            return $0.item.id.uuidString < $1.item.id.uuidString
        }.map(\.item)
        guard hasModel && !broad else { return Array(lexical.prefix(5)) }
        let found = try await semantic.matches(
            query, passages: passages, allowed: Set(passages.map(\.sourceID)), limit: 12)
        let ordered = SemanticPassageIndex.fused(
            lexical: Array(lexical.prefix(12)).map(\.id), semantic: found.map(\.passage.sourceID))
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        return ordered.prefix(5).compactMap { byID[$0] }
    }

    public func prepare(_ state: LibraryState) async throws {
        guard usesVectors, await semantic.isAvailable() else { return }
        let origins = ResearchMemoryOrigins(state: state, excluding: [])
        let passages = state.memories.filter {
            !$0.deleted && !$0.text.isEmpty && !$0.isResponsePreference && origins.resolve($0) != nil
        }.map(Self.passage)
        try await semantic.prepare(passages)
    }

    private static func passage(_ memory: MemoryItem) -> SemanticPassage {
        let text =
            memory.text.hasPrefix(MemoryItem.automaticPrefix)
            ? String(memory.text.dropFirst(MemoryItem.automaticPrefix.count)) : memory.text
        return SemanticPassage(sourceID: memory.id, text: text)
    }

    private static let stopWords: Set<String> = [
        "的", "了", "我", "你", "在", "是", "与", "和", "这", "论文", "研究", "阅读", "什么", "是否", "为什么",
        "the", "a", "of", "for", "in", "is", "and", "paper", "what", "how",
    ]

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
