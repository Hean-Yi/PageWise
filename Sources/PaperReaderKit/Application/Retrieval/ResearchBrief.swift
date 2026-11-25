import Foundation

/// A bounded selection from the local library. The prompts receive only the public topics.
public struct ResearchBrief: Encodable, Sendable {
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

        public init(
            id: String, version: String, label: String, basis: String, paperCount: Int, notedPapers: Int,
            discussedPapers: Int, sources: [Source]
        ) {
            self.id = id
            self.version = version
            self.label = label
            self.basis = basis
            self.paperCount = paperCount
            self.notedPapers = notedPapers
            self.discussedPapers = discussedPapers
            self.sources = sources
        }

        enum CodingKeys: String, CodingKey {
            case label, basis, paperCount, notedPapers, discussedPapers, sources
        }
    }

    public let topics: [Topic]
    /// The source generation and time the persisted index had covered when this brief was read.
    public let researchRevision: Int64?
    public let coveredAt: Date?
    let inputs: BriefInputs
    let versions: ChatSourceVersions
    enum CodingKeys: String, CodingKey { case topics }

    init(
        topics: [Topic], inputs: BriefInputs, versions: ChatSourceVersions, researchRevision: Int64? = nil,
        coveredAt: Date? = nil
    ) {
        self.topics = topics
        self.inputs = inputs
        self.versions = versions
        self.researchRevision = researchRevision
        self.coveredAt = coveredAt
    }

    public func isCurrent(in state: LibraryState, excluding pending: Set<UUID>) -> Bool {
        guard inputs == BriefInputs(state, excluding: pending), versions.isCurrent(in: state, excluding: pending) else {
            return false
        }
        let quoted = topics.flatMap(\.sources).compactMap { source -> (UUID, String)? in
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
    let papers: [UUID: PaperInfo]
    let shelves: [UUID: String]
    let noted: Set<UUID>
    let discussed: Set<UUID>

    init(_ state: LibraryState, excluding pending: Set<UUID>) {
        papers = Dictionary(
            state.papers.lazy.filter { !pending.contains($0.id) }.map {
                ($0.id, PaperInfo(title: $0.title, shelf: state.paperShelfIDs[$0.id.uuidString]))
            }, uniquingKeysWith: { first, _ in first })
        shelves = Dictionary(state.shelves.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
