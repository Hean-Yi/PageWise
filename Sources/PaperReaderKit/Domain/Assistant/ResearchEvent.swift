import CryptoKit
import Foundation

/// A source change that a rebuildable research index may need to reconcile. Events carry only
/// stable record IDs, a content revision and the owning paper/shelf; prose stays in the library.
public struct ResearchEvent: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paperImported
        case paperChanged
        case paperRemoved
        case paperEngaged
        case noteChanged
        case noteRemoved
        case discussionChanged
        case discussionRemoved
        case memoryChanged
        case memoryRemoved
        case shelfChanged
        case paperShelfChanged
    }

    public let kind: Kind
    public let recordID: UUID
    public let paperID: UUID?
    public let shelfID: UUID?
    public let recordRevision: String
    public let occurredAt: Date

    public init(
        kind: Kind, recordID: UUID, paperID: UUID? = nil, shelfID: UUID? = nil,
        recordRevision: String, occurredAt: Date
    ) {
        self.kind = kind
        self.recordID = recordID
        self.paperID = paperID
        self.shelfID = shelfID
        self.recordRevision = recordRevision
        self.occurredAt = occurredAt
    }

    /// The same record revision may be retried after a failed import or an interrupted save.
    /// The library generation, not this key, orders changes that return to an earlier revision.
    public var key: String { "\(kind.rawValue)|\(recordID.uuidString)|\(recordRevision)" }
}

public enum ResearchEngagement: String, Sendable {
    case opened
    case translated
    case noted
}

public struct StoredResearchEvent: Equatable, Sendable {
    public let sequence: Int64
    public let event: ResearchEvent

    public init(sequence: Int64, event: ResearchEvent) {
        self.sequence = sequence
        self.event = event
    }
}

/// Checkpoint for the rebuildable brief/note/memory index. The source generation advances on
/// every research-relevant commit, including one whose event key was already seen.
public struct ResearchIndexState: Codable, Equatable, Sendable {
    public var lastResearchRevision: Int64
    public var lastEventSequence: Int64
    public var lastAuditAt: Date?
    public var format: Int

    public init(
        lastResearchRevision: Int64 = 0, lastEventSequence: Int64 = 0, lastAuditAt: Date? = nil, format: Int = 1
    ) {
        self.lastResearchRevision = lastResearchRevision
        self.lastEventSequence = lastEventSequence
        self.lastAuditAt = lastAuditAt
        self.format = format
    }
}

struct ResearchMaintenanceSnapshot: Sendable {
    let state: LibraryState
    let libraryRevision: Int64
    let researchRevision: Int64
    let pendingEvents: [StoredResearchEvent]
    let indexState: ResearchIndexState?
}

/// Compares two committed library snapshots. Callers gate this on a research-source change so
/// ordinary reading-position, translation and workspace saves never build a diff.
enum ResearchEventBuilder {
    static func events(from old: LibraryState, to new: LibraryState, occurredAt: Date) -> [ResearchEvent] {
        var events: [ResearchEvent] = []
        let oldPapers = Dictionary(old.papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newPapers = Dictionary(new.papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for paper in new.papers {
            guard let previous = oldPapers[paper.id] else {
                events.append(
                    ResearchEvent(
                        kind: .paperImported, recordID: paper.id, paperID: paper.id,
                        recordRevision: paperRevision(paper), occurredAt: occurredAt))
                continue
            }
            if paperRevision(previous) != paperRevision(paper) {
                events.append(
                    ResearchEvent(
                        kind: .paperChanged, recordID: paper.id, paperID: paper.id,
                        recordRevision: paperRevision(paper), occurredAt: occurredAt))
            }
        }
        for paper in old.papers where newPapers[paper.id] == nil {
            events.append(
                ResearchEvent(
                    kind: .paperRemoved, recordID: paper.id, paperID: paper.id,
                    recordRevision: paperRevision(paper), occurredAt: occurredAt))
        }

        let oldNotes = Dictionary(old.readingNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newNotes = Dictionary(new.readingNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for note in new.readingNotes {
            guard let previous = oldNotes[note.id] else {
                events.append(
                    ResearchEvent(
                        kind: note.deletedAt == nil ? .noteChanged : .noteRemoved, recordID: note.id,
                        paperID: note.paperID, recordRevision: digest(note), occurredAt: occurredAt))
                continue
            }
            guard previous != note else { continue }
            let kind: ResearchEvent.Kind =
                note.deletedAt != nil && previous.deletedAt == nil ? .noteRemoved : .noteChanged
            events.append(
                ResearchEvent(
                    kind: kind, recordID: note.id, paperID: note.paperID, recordRevision: digest(note),
                    occurredAt: occurredAt))
        }
        for note in old.readingNotes where newNotes[note.id] == nil {
            events.append(
                ResearchEvent(
                    kind: .noteRemoved, recordID: note.id, paperID: note.paperID, recordRevision: digest(note),
                    occurredAt: occurredAt))
        }

        let oldChats = Dictionary(old.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newChats = Dictionary(new.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for chat in new.chats {
            if oldChats[chat.id] != chat {
                events.append(
                    ResearchEvent(
                        kind: .discussionChanged, recordID: chat.id, paperID: chat.paperID,
                        recordRevision: digest(chat), occurredAt: occurredAt))
            }
        }
        for chat in old.chats where newChats[chat.id] == nil {
            events.append(
                ResearchEvent(
                    kind: .discussionRemoved, recordID: chat.id, paperID: chat.paperID,
                    recordRevision: digest(chat), occurredAt: occurredAt))
        }

        let oldMemories = Dictionary(old.memories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newMemories = Dictionary(new.memories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for memory in new.memories {
            guard let previous = oldMemories[memory.id] else {
                events.append(
                    ResearchEvent(
                        kind: memory.deleted ? .memoryRemoved : .memoryChanged, recordID: memory.id,
                        paperID: paperID(for: memory, in: new, fallback: old),
                        recordRevision: digest(memory), occurredAt: occurredAt))
                continue
            }
            guard previous != memory else { continue }
            let kind: ResearchEvent.Kind =
                memory.deleted && !previous.deleted ? .memoryRemoved : .memoryChanged
            events.append(
                ResearchEvent(
                    kind: kind, recordID: memory.id,
                    paperID: paperID(for: memory, in: new, fallback: old),
                    recordRevision: digest(memory), occurredAt: occurredAt))
        }
        for memory in old.memories where newMemories[memory.id] == nil {
            events.append(
                ResearchEvent(
                    kind: .memoryRemoved, recordID: memory.id,
                    paperID: paperID(for: memory, in: old, fallback: new),
                    recordRevision: digest(memory), occurredAt: occurredAt))
        }

        let oldShelves = Dictionary(old.shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newShelves = Dictionary(new.shelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for shelf in new.shelves {
            guard oldShelves[shelf.id] != shelf else { continue }
            events.append(
                ResearchEvent(
                    kind: .shelfChanged, recordID: shelf.id, shelfID: shelf.id,
                    recordRevision: digest(shelf), occurredAt: occurredAt))
        }
        for shelf in old.shelves where newShelves[shelf.id] == nil {
            events.append(
                ResearchEvent(
                    kind: .shelfChanged, recordID: shelf.id, shelfID: shelf.id,
                    recordRevision: digest(shelf), occurredAt: occurredAt))
        }

        let retainedPapers = Set(newPapers.keys)
        let shelfKeys = Set(old.paperShelfIDs.keys).union(new.paperShelfIDs.keys)
        for key in shelfKeys {
            guard let paperID = UUID(uuidString: key) else { continue }
            let previous = old.paperShelfIDs[key]
            let next = new.paperShelfIDs[key]
            guard previous != next, retainedPapers.contains(paperID) else { continue }
            events.append(
                ResearchEvent(
                    kind: .paperShelfChanged, recordID: paperID, paperID: paperID, shelfID: next,
                    recordRevision: "\(previous?.uuidString ?? "none")>\(next?.uuidString ?? "none")",
                    occurredAt: occurredAt))
        }

        return events.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.recordID != $1.recordID { return $0.recordID.uuidString < $1.recordID.uuidString }
            return $0.recordRevision < $1.recordRevision
        }
    }

    private struct PaperSnapshot: Encodable {
        let title: String
        let digest: String
    }

    private static func paperRevision(_ paper: Paper) -> String {
        digest(PaperSnapshot(title: paper.title, digest: paper.digest))
    }

    private static func paperID(for memory: MemoryItem, in state: LibraryState, fallback: LibraryState) -> UUID? {
        switch memory.librarySource {
        case .note(let paperID, _):
            return paperID
        case .reader:
            return nil
        case nil:
            return state.chats.first(where: { $0.id == memory.sourceID })?.paperID
                ?? fallback.chats.first(where: { $0.id == memory.sourceID })?.paperID
        }
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return "unencodable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
