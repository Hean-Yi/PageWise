import Foundation

public enum LibraryOrderChange: Sendable {
    case select(LibrarySort)
    /// Only these visible slots change. Hidden papers retain their relative positions.
    case arrange(original: [UUID], reordered: [UUID], unfinishedFirst: Bool)
}

extension LibraryState {
    public func validateOrdering() throws {
        guard Set(manualPaperIDs).count == manualPaperIDs.count,
            Set(manualPaperIDs).isSubset(of: Set(papers.map(\.id)))
        else { throw ReaderError.message("自定义顺序包含无效论文，原资料已保留。") }
    }

    public mutating func apply(_ change: LibraryOrderChange) throws {
        switch change {
        case .select(let sort): preferredSort = sort
        case .arrange(let original, let reordered, let unfinishedFirst):
            let ids = Set(original)
            guard !original.isEmpty, ids.count == original.count,
                Set(reordered) == ids, reordered.count == original.count,
                ids.isSubset(of: Set(papers.map(\.id)))
            else { throw ReaderError.message("论文顺序已失效，未调整。") }
            if unfinishedFirst {
                let finished = Set(LibraryQuery.papers(in: self, collection: .finished).map(\.id))
                guard
                    original.filter({ !finished.contains($0) }).count
                        == reordered.prefix(while: { !finished.contains($0) }).count
                else { throw ReaderError.message("已读论文只能在已读组内调整。") }
            }
            // Seed from the selected sort, including papers hidden by a query or shelf.
            var order = LibraryQuery.papers(in: self, sort: preferredSort).map(\.id)
            var replacement = reordered.makeIterator()
            for index in order.indices where ids.contains(order[index]) {
                order[index] = replacement.next()!
            }
            manualPaperIDs = order
            preferredSort = .manual
        }
        try validateOrdering()
    }
}
