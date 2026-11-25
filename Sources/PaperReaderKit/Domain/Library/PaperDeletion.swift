import Foundation

extension LibraryState {
    @discardableResult public mutating func removePaper(_ id: UUID) throws -> Paper {
        guard let index = papers.firstIndex(where: { $0.id == id }) else {
            throw ReaderError.message("这篇论文已不在书库中。")
        }
        let turnIDs = Set(chats.lazy.filter { $0.paperID == id }.map(\.id))
        var rejected = Set<String>()
        memories.removeAll { item in
            if item.preference?.scope == .paper(id) {
                rejected.formUnion(item.rejectedFingerprints)
                return true
            }
            switch item.librarySource {
            case .note(let sourcePaper, _) where sourcePaper == id: break
            case nil where turnIDs.contains(item.sourceID): break
            default: return false
            }
            rejected.formUnion(item.rejectedFingerprints)
            return true
        }
        suppressedMemoryFingerprints.formUnion(rejected)
        chats.removeAll { $0.paperID == id }
        readingNotes.removeAll { $0.paperID == id }
        highlights.removeAll { $0.paperID == id }
        bookmarks.removeAll { $0.paperID == id }
        reading.removeAll { $0.paperID == id }
        manualPaperIDs.removeAll { $0 == id }
        paperShelfIDs.removeValue(forKey: id.uuidString)
        workspace.removeValue(forKey: id.uuidString)
        return papers.remove(at: index)
    }

    // v11 moved these records out of the active library without confirming permanent removal.
    mutating func migrateVersion11(from decoder: any Decoder) throws {
        enum Keys: CodingKey { case trashedPapers }
        let values = try decoder.container(keyedBy: Keys.self)
        let archive = try values.decode([LegacyDeletedPaper].self, forKey: .trashedPapers)
        var ids = Set(papers.map(\.id))
        for (index, entry) in archive.enumerated() {
            let id = entry.paper.id
            guard ids.insert(id).inserted else {
                throw ReaderError.message("旧版书库包含重复的论文，原有数据已保留。")
            }
            let remaining = archive.suffix(from: index + 1)
            let slot = entry.position.slot(in: papers.map(\.id), hidden: remaining.map(\.position.index))
            papers.insert(entry.paper, at: slot)
            if let position = entry.manualPosition {
                let slot = position.slot(in: manualPaperIDs, hidden: remaining.compactMap { $0.manualPosition?.index })
                manualPaperIDs.insert(id, at: slot)
            }
            if let shelf = entry.shelfID, shelves.contains(where: { $0.id == shelf }) {
                paperShelfIDs[id.uuidString] = shelf
            }
            workspace[id.uuidString] = entry.workspace
            readingNotes += entry.readingNotes
            highlights += entry.highlights
            chats += entry.chats
            memories += entry.memories
            reading += entry.reading
            bookmarks += entry.bookmarks
        }
        if !archive.isEmpty { memories.sort { $0.createdAt < $1.createdAt } }
    }
}

private struct LegacyDeletedPaper: Decodable {
    struct Position: Decodable {
        let index: Int
        let previous: UUID?
        let next: UUID?

        func slot(in ids: [UUID], hidden: [Int]) -> Int {
            let lower = previous.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let upper = next.flatMap { ids.firstIndex(of: $0) } ?? ids.count
            return min(max(lower, index - hidden.count { $0 < index }), upper)
        }
    }
    let paper: Paper
    let position: Position
    let manualPosition: Position?
    let shelfID: UUID?
    let workspace: PaperWorkspace?
    let readingNotes: [ReadingNote]
    let highlights: [Highlight]
    let chats: [ChatTurn]
    let memories: [MemoryItem]
    let reading: [ReadingEntry]
    let bookmarks: [PageBookmark]
}
