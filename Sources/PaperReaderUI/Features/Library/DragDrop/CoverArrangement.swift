import Foundation
import Observation

/// Keep the hit targets fixed. Only the dragged cover and its intervening neighbors move.
@MainActor @Observable final class CoverArrangement {
    private(set) var sourceID: UUID?
    private(set) var destinationIndex: Int?
    private var original: [UUID] = []
    private var slots: [UUID: Int] = [:]
    private var firstFinishedIndex: Int?
    private var unfinishedFirst = false
    private(set) var committing = false

    private var sourceIndex: Int? { sourceID.flatMap { slots[$0] } }

    var preview: [UUID] {
        guard let from = sourceIndex, let to = destinationIndex, from != to else { return original }
        var result = original
        let id = result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    func begin(_ id: UUID, visible: [UUID], firstFinishedIndex: Int?, unfinishedFirst: Bool) {
        guard !committing, let index = visible.firstIndex(of: id) else { return }
        original = visible
        slots = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1, $0) })
        sourceID = id
        destinationIndex = index
        self.firstFinishedIndex = firstFinishedIndex
        self.unfinishedFirst = unfinishedFirst
    }

    func accepts(_ id: UUID, at slot: UUID) -> Bool {
        guard !committing, id == sourceID, let from = sourceIndex, let to = slots[slot] else { return false }
        guard let boundary = firstFinishedIndex else { return true }
        return (from < boundary) == (to < boundary)
    }

    func hover(_ id: UUID, at slot: UUID) {
        guard accepts(id, at: slot), let next = slots[slot], next != destinationIndex else { return }
        destinationIndex = next
    }

    func offset(for id: UUID) -> Int {
        guard let index = slots[id], let from = sourceIndex, let to = destinationIndex else { return 0 }
        if index == from { return to - from }
        if from < index && index <= to { return -1 }
        if to <= index && index < from { return 1 }
        return 0
    }

    func end() {
        guard !committing else { return }
        sourceID = nil
        destinationIndex = nil
        original = []
        slots = [:]
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
