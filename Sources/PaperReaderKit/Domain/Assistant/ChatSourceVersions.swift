import CryptoKit
import Foundation

/// Dependencies of the answer, including sources inherited through earlier dialogue.
/// Store identifiers and fingerprints so revocation never requires retaining the withdrawn text here.
public struct ChatSourceVersions: Codable, Sendable, Equatable {
    private var memories: [UUID: String] = [:]
    private var notes: [UUID: Date] = [:]

    /// The active research representation used to compose this dialogue. Raw evidence keeps
    /// its independent source fingerprint even if a later idle session changes the working memory.
    public var sleepRevision: UUID?

    public init() {}

    public mutating func include(_ memory: MemoryItem) {
        if memories[memory.id] == nil { memories[memory.id] = Self.fingerprint(memory) }
    }

    public mutating func include(_ note: ReadingNote) {
        if let ancestors = note.backgroundSources { include(ancestors) }
        if notes[note.id] == nil { notes[note.id] = note.modifiedAt }
    }

    public mutating func include(_ other: Self) {
        sleepRevision = sleepRevision ?? other.sleepRevision
        memories.merge(other.memories) { current, _ in current }
        notes.merge(other.notes) { current, _ in current }
    }

    public var memoryIDs: Set<UUID> { Set(memories.keys) }

    public var isEmpty: Bool { memories.isEmpty && notes.isEmpty }

    public var permitsHistory: Bool { memories.count + notes.count <= 48 }

    public func isCurrent(in state: LibraryState, excluding pending: Set<UUID>) -> Bool {
        guard !memories.isEmpty || !notes.isEmpty else { return true }
        let current = Self.live(in: state, excluding: pending, memoryIDs: Set(memories.keys), noteIDs: Set(notes.keys))
        return matches(current)
    }

    /// Old AI reports did not store every input. Keep a documented link only while its original text and edition still verify.
    private static func legacyDependencies(in state: LibraryState, excluding pending: Set<UUID>) -> (
        known: Set<UUID>, resolved: [UUID: Self]
    ) {
        let known = Set(state.chats.flatMap { ($0.closeReadingNoteIDs ?? []) + [$0.readingNoteID].compactMap { $0 } })
        guard !known.isEmpty else { return ([], [:]) }
        let records = Dictionary(state.readingNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let legacy = known.filter { records[$0]?.backgroundSources == nil }
        guard !legacy.isEmpty else { return ([], [:]) }
        let papers = Dictionary(state.papers.map { ($0.id, $0.digest) }, uniquingKeysWith: { first, _ in first })
        var resolved: [UUID: Self] = [:]
        var unavailable = Set<UUID>()
        func resolve(_ id: UUID, path: Set<UUID>) -> Self? {
            if let saved = resolved[id] { return saved }
            guard !unavailable.contains(id), !path.contains(id), path.count < 16, let note = records[id],
                note.deletedAt == nil
            else { return nil }
            defer { if resolved[id] == nil { unavailable.insert(id) } }
            let links = note.citations?.filter { $0.readingNoteID != nil } ?? []
            guard !links.isEmpty, links.count <= LocalPassageCitation.notebookLimit else { return nil }
            var versions = Self()
            for link in links {
                guard let targetID = link.readingNoteID, var target = records[targetID], target.paperID == link.paperID,
                    !pending.contains(target.paperID), papers[target.paperID] == link.digest, target.deletedAt == nil,
                    target.modifiedAt <= note.createdAt, target.contentVersion == link.contentVersion,
                    !link.quote.isEmpty,
                    ReadingNoteMemoryIndex.searchableBody(target.markdown).contains(link.quote)
                else { return nil }
                if legacy.contains(targetID) {
                    guard let ancestors = resolve(targetID, path: path.union([id])) else { return nil }
                    target.backgroundSources = ancestors
                }
                versions.include(target)
            }
            resolved[id] = versions
            return versions
        }
        for id in legacy where resolve(id, path: []) == nil { unavailable.insert(id) }
        return (legacy, resolved)
    }

    public static func recalledNote(_ note: ReadingNote, in state: LibraryState, excluding pending: Set<UUID>)
        -> ReadingNote?
    {
        var note = note
        if note.backgroundSources == nil,
            state.chats.contains(where: {
                $0.readingNoteID == note.id || $0.closeReadingNoteIDs?.contains(note.id) == true
            })
        {
            let legacy = legacyDependencies(in: state, excluding: pending)
            if legacy.known.contains(note.id) {
                guard let sources = legacy.resolved[note.id] else { return nil }
                note.backgroundSources = sources
            }
        }
        return note.backgroundSources?.isCurrent(in: state, excluding: pending) == false ? nil : note
    }

    /// Resolve each source ID only once, even if a long close reading produced many dependent notes.
    static func withdrawnNoteIDs(in state: LibraryState, excluding pending: Set<UUID>) -> Set<UUID> {
        let legacy = legacyDependencies(in: state, excluding: pending)
        var unavailable = legacy.known.subtracting(legacy.resolved.keys)
        var memoryIDs = Set<UUID>()
        var noteIDs = Set<UUID>()
        for note in state.readingNotes {
            if let sources = note.backgroundSources ?? legacy.resolved[note.id] {
                memoryIDs.formUnion(sources.memories.keys)
                noteIDs.formUnion(sources.notes.keys)
            }
        }
        guard !memoryIDs.isEmpty || !noteIDs.isEmpty else { return unavailable }
        let current = Self.live(in: state, excluding: pending, memoryIDs: memoryIDs, noteIDs: noteIDs)
        for note in state.readingNotes
        where (note.backgroundSources ?? legacy.resolved[note.id])?.matches(current) == false {
            unavailable.insert(note.id)
        }
        return unavailable
    }

    private func matches(_ current: Self) -> Bool {
        memories.allSatisfy { current.memories[$0.key] == $0.value }
            && notes.allSatisfy { current.notes[$0.key] == $0.value }
    }

    private static func live(
        in state: LibraryState, excluding pending: Set<UUID>, memoryIDs: Set<UUID>, noteIDs: Set<UUID>
    ) -> Self {
        var result = Self()
        let papers = Set(state.papers.lazy.map(\.id)).subtracting(pending)
        if !memoryIDs.isEmpty {
            let origins = ResearchMemoryOrigins(state: state, excluding: pending)
            for item in state.memories where memoryIDs.contains(item.id) && origins.resolve(item) != nil {
                result.include(item)
            }
        }
        if !noteIDs.isEmpty {
            for note in state.readingNotes
            where noteIDs.contains(note.id) && note.deletedAt == nil && papers.contains(note.paperID) {
                result.notes[note.id] = note.modifiedAt
            }
        }
        return result
    }

    private static func fingerprint(_ memory: MemoryItem) -> String {
        var content = memory.sourceID.uuidString + (memory.userEdited ? "|1|" : "|0|") + memory.text.prefix(400)
        if let revision = memory.correctionRevision { content += "|revision|" + revision.uuidString }
        if let invalidAt = memory.invalidAt {
            content += "|invalid|" + String(invalidAt.timeIntervalSinceReferenceDate.bitPattern)
        }
        switch memory.librarySource {
        case .reader(let quote): content += "|reader|" + quote
        case .note(let paperID, let modifiedAt):
            content +=
                "|note|" + paperID.uuidString + "|" + String(modifiedAt.timeIntervalSinceReferenceDate.bitPattern)
        case .paper(let paperID):
            content += "|paper|" + paperID.uuidString
        case nil: break
        }
        return Data(SHA256.hash(data: Data(content.utf8))).base64EncodedString()
    }
}
