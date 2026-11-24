import Foundation

public enum PaperTrashChange: Sendable {
    case trash(UUID, at: Date)
    case restore(UUID, deletedAt: Date)
}

/// Files stay at their immutable paths. Related records travel together so active readers and indexes
/// only see live material, and restoring the paper reconnects existing cross-paper citations by ID.
public struct TrashedPaper: Codable, Identifiable, Sendable {
    public var id: UUID { paper.id }
    public let paper: Paper
    public let deletedAt: Date
    fileprivate let position: TrashPosition
    fileprivate let manualPosition: TrashPosition?
    fileprivate let shelfID: UUID?
    fileprivate let workspace: PaperWorkspace?
    fileprivate let readingNotes: [ReadingNote]
    fileprivate let highlights: [Highlight]
    fileprivate let chats: [ChatTurn]
    fileprivate let memories: [MemoryItem]
    fileprivate let reading: [ReadingEntry]
    fileprivate let bookmarks: [PageBookmark]
}

private struct TrashPosition: Codable, Sendable {
    let index: Int
    let previous: UUID?
    let next: UUID?

    init(at index: Int, in ids: [UUID], hiddenSlots: [Int]) {
        var fullIndex = index
        for slot in hiddenSlots.sorted() where slot <= fullIndex { fullIndex += 1 }
        self.index = fullIndex
        previous = index > 0 ? ids[index - 1] : nil
        next = index + 1 < ids.count ? ids[index + 1] : nil
    }

    func insertionIndex(in ids: [UUID], hiddenSlots: [Int]) -> Int {
        let lower = previous.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let upper = next.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        let visibleIndex = index - hiddenSlots.count { $0 < index }
        return min(max(lower, visibleIndex), upper)
    }
}

extension LibraryState {
    public mutating func apply(_ change: PaperTrashChange) throws {
        switch change {
        case .trash(let id, let date):
            guard let index = papers.firstIndex(where: { $0.id == id }) else {
                throw ReaderError.message("找不到要删除的论文。")
            }
            let position = TrashPosition(
                at: index, in: papers.map(\.id), hiddenSlots: trashedPapers.map(\.position.index))
            let paper = papers.remove(at: index)
            let manualIndex = manualPaperIDs.firstIndex(of: id)
            let manualPosition = manualIndex.map {
                TrashPosition(
                    at: $0, in: manualPaperIDs, hiddenSlots: trashedPapers.compactMap { $0.manualPosition?.index })
            }
            if let manualIndex { manualPaperIDs.remove(at: manualIndex) }
            let turns = chats.extract { $0.paperID == id }
            let turnIDs = Set(turns.map(\.id))
            let archived = TrashedPaper(
                paper: paper, deletedAt: date, position: position, manualPosition: manualPosition,
                shelfID: paperShelfIDs.removeValue(forKey: id.uuidString),
                workspace: workspace.removeValue(forKey: id.uuidString),
                readingNotes: readingNotes.extract { $0.paperID == id },
                highlights: highlights.extract { $0.paperID == id }, chats: turns,
                memories: memories.extract { turnIDs.contains($0.sourceID) },
                reading: reading.extract { $0.paperID == id }, bookmarks: bookmarks.extract { $0.paperID == id })
            trashedPapers.insert(archived, at: 0)
        case .restore(let id, let deletedAt):
            guard let index = trashedPapers.firstIndex(where: { $0.id == id }) else {
                throw ReaderError.message("找不到要恢复的论文。")
            }
            let archived = trashedPapers[index]
            guard archived.deletedAt == deletedAt else { throw ReaderError.message("删除记录已变化，请重新选择要恢复的论文。") }
            guard !papers.contains(where: { $0.id == id || $0.digest == archived.paper.digest }) else {
                throw ReaderError.message("书库中已有这篇论文，原记录仍在最近删除中。")
            }
            trashedPapers.remove(at: index)
            let slot = archived.position.insertionIndex(
                in: papers.map(\.id), hiddenSlots: trashedPapers.map(\.position.index))
            papers.insert(archived.paper, at: slot)
            if let slot = archived.manualPosition {
                let manualIndex = slot.insertionIndex(
                    in: manualPaperIDs, hiddenSlots: trashedPapers.compactMap { $0.manualPosition?.index })
                manualPaperIDs.insert(id, at: manualIndex)
            }
            if let shelf = archived.shelfID, shelves.contains(where: { $0.id == shelf }) {
                paperShelfIDs[id.uuidString] = shelf
            }
            workspace[id.uuidString] = archived.workspace
            readingNotes += archived.readingNotes
            highlights += archived.highlights
            chats += archived.chats
            reading += archived.reading
            bookmarks += archived.bookmarks
            // Research memory across papers is consumed in chronological order.
            if !archived.memories.isEmpty {
                memories += archived.memories
                memories.sort { $0.createdAt < $1.createdAt }
            }
        }
    }

    public func validateTrash() throws {
        guard !trashedPapers.isEmpty else { return }
        let removed = Set(trashedPapers.map(\.id))
        guard removed.count == trashedPapers.count, removed.isDisjoint(with: papers.map(\.id)) else {
            throw ReaderError.message("最近删除包含重复论文，已有资料已保留。")
        }
    }
}

extension Array {
    fileprivate mutating func extract(where matching: (Element) -> Bool) -> [Element] {
        let extracted = filter(matching)
        removeAll(where: matching)
        return extracted
    }
}
