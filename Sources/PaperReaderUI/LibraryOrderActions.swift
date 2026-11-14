import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func selectLibrarySort(_ sort: LibrarySort) async -> Bool {
        await save(cancellable: true, orderChange: .select(sort))
    }

    @discardableResult public func arrangePapers(
        original: [UUID], reordered: [UUID], unfinishedFirst: Bool
    ) async -> Bool {
        await save(
            cancellable: true,
            orderChange: .arrange(original: original, reordered: reordered, unfinishedFirst: unfinishedFirst))
    }
}

/// Temporary drag state never mutates the library. Destinations are stationary grid slots,
/// so a neighboring cover moving under the cursor cannot reverse the previous preview.
@MainActor @Observable final class CoverArrangement {
    private(set) var sourceID: UUID?
    private(set) var original: [UUID] = []
    private(set) var preview: [UUID] = []
    private var finished: Set<UUID> = []
    private var unfinishedFirst = false
    private(set) var committing = false

    func begin(_ id: UUID, visible: [UUID], state: LibraryState, unfinishedFirst: Bool) {
        guard !committing, visible.contains(id) else { return }
        sourceID = id
        original = visible
        preview = visible
        finished = Set(LibraryQuery.papers(in: state, collection: .finished).map(\.id))
        self.unfinishedFirst = unfinishedFirst
    }

    func accepts(_ id: UUID, at slot: UUID) -> Bool {
        sourceID == id && original.contains(slot) && !committing
            && (!unfinishedFirst || finished.contains(id) == finished.contains(slot))
    }

    func hover(_ id: UUID, at slot: UUID) {
        guard accepts(id, at: slot), let destination = original.firstIndex(of: slot) else { return }
        var next = original.filter { $0 != id }
        next.insert(id, at: destination)
        preview = next
    }

    func offset(for id: UUID) -> Int {
        guard let from = original.firstIndex(of: id), let to = preview.firstIndex(of: id) else { return 0 }
        return to - from
    }

    func end() {
        guard !committing else { return }
        sourceID = nil
        preview = []
        original = []
    }

    func reserveDrop() -> Bool {
        guard sourceID != nil, !committing else { return false }
        committing = true
        return true
    }

    func commit(model: ReaderModel) async -> Bool {
        guard sourceID != nil, committing else { return false }
        let result = await model.arrangePapers(
            original: original, reordered: preview, unfinishedFirst: unfinishedFirst)
        committing = false
        end()
        return result
    }
}
