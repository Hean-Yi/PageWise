import Foundation

/// A bounded selection from the local library. The prompts receive only the public topics.
public struct ResearchBrief: Encodable, Sendable {
    public enum Scope: Equatable, Sendable {
        case library
        case shelf(UUID)
        case paper(UUID)

        public func includes(paperID: UUID, shelfID: UUID?) -> Bool {
            switch self {
            case .library: true
            case .shelf(let id): shelfID == id
            case .paper(let id): paperID == id
            }
        }
    }

    public let id = UUID()
    public struct Source: Encodable, Sendable, Equatable {
        public let paperID: UUID
        public let title: String
        public let noteID: UUID?
        public let excerpt: String?
        public let noteOrigin: String?
    }

    public struct Topic: Encodable, Sendable, Equatable {
        /// Stable across queries for the same shelf/title-topic; a query-specific note group uses
        /// the query text so repeated requests can refer to the same topic.
        public let id: String
        /// Changes when the topic's member set, label or basis changes, without exposing prose.
        public let version: String
        public let label: String
        public let basis: String
        public let paperCount: Int
        public let notedPapers: Int
        public let discussedPapers: Int
        public let sources: [Source]
        /// Tentative agent questions linked to this topic; never reader-endorsed facts.
        public let openQuestions: [String]
        /// Reader notes marked as concessions or rebuttals for a member paper.
        public let counterNotes: [Source]

        public init(
            id: String, version: String, label: String, basis: String, paperCount: Int, notedPapers: Int,
            discussedPapers: Int, sources: [Source], openQuestions: [String] = [], counterNotes: [Source] = []
        ) {
            self.id = id
            self.version = version
            self.label = label
            self.basis = basis
            self.paperCount = paperCount
            self.notedPapers = notedPapers
            self.discussedPapers = discussedPapers
            self.sources = sources
            self.openQuestions = openQuestions
            self.counterNotes = counterNotes
        }

        enum CodingKeys: String, CodingKey {
            case label, basis, paperCount, notedPapers, discussedPapers, sources, openQuestions, counterNotes
        }
    }

    public let topics: [Topic]
    public let scope: Scope
    /// The source generation and time the persisted index had covered when this brief was read.
    public let researchRevision: Int64?
    public let coveredAt: Date?
    let inputs: BriefInputs
    let versions: ChatSourceVersions
    enum CodingKeys: String, CodingKey { case topics }

    init(
        topics: [Topic], scope: Scope = .library, inputs: BriefInputs, versions: ChatSourceVersions,
        researchRevision: Int64? = nil, coveredAt: Date? = nil
    ) {
        self.topics = topics
        self.scope = scope
        self.inputs = inputs
        self.versions = versions
        self.researchRevision = researchRevision
        self.coveredAt = coveredAt
    }

    public func isCurrent(in state: LibraryState, excluding pending: Set<UUID>) -> Bool {
        guard inputs == BriefInputs(state, excluding: pending, scope: scope),
            versions.isCurrent(in: state, excluding: pending)
        else {
            return false
        }
        let quoted = topics.flatMap { $0.sources + $0.counterNotes }.compactMap { source -> (UUID, String)? in
            guard let id = source.noteID, let excerpt = source.excerpt else { return nil }
            return (id, excerpt)
        }
        guard !quoted.isEmpty else { return true }
        let ids = Set(quoted.map { $0.0 })
        let notes = Dictionary(
            state.readingNotes.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return quoted.allSatisfy { id, excerpt in
            guard let note = notes[id], note.deletedAt == nil,
                ChatSourceVersions.recalledNote(note, in: state, excluding: pending) != nil
            else { return false }
            return ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(excerpt)
        }
    }
}

struct BriefInputs: Equatable, Sendable {
    struct PaperInfo: Equatable, Sendable {
        let title: String
        let shelf: UUID?
    }
    let scope: ResearchBrief.Scope
    let papers: [UUID: PaperInfo]
    let shelves: [UUID: String]
    let noted: Set<UUID>
    let discussed: Set<UUID>

    init(_ state: LibraryState, excluding pending: Set<UUID>, scope: ResearchBrief.Scope = .library) {
        self.scope = scope
        papers = Dictionary(
            state.papers.lazy.filter {
                !pending.contains($0.id)
                    && scope.includes(
                        paperID: $0.id, shelfID: state.paperShelfIDs[$0.id.uuidString])
            }.map {
                ($0.id, PaperInfo(title: $0.title, shelf: state.paperShelfIDs[$0.id.uuidString]))
            }, uniquingKeysWith: { first, _ in first })
        let scopedShelves = Set(papers.values.compactMap(\.shelf))
        shelves = Dictionary(
            state.shelves.lazy.filter { scopedShelves.contains($0.id) }.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        let live = Set(papers.keys)
        let withdrawn = ChatSourceVersions.withdrawnNoteIDs(in: state, excluding: pending)
        noted = Set(
            state.readingNotes.lazy.filter {
                $0.deletedAt == nil && live.contains($0.paperID) && !withdrawn.contains($0.id)
            }.map(\.paperID))
        discussed = Set(
            state.chats.lazy.filter { $0.closeReadingVersion == nil && live.contains($0.paperID) }.map(\.paperID))
    }
}
