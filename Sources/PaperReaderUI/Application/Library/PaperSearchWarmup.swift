import Foundation
import PaperReaderKit

/// One low-priority worker per open library. Rapid imports coalesce by ID without retaining the reader.
@MainActor
final class PaperSearchWarmup {
    let index: LibraryAgentSearchIndex

    init(root: URL) { index = LibraryAgentSearchIndex(root: root) }
    private var pending: [UUID: Paper] = [:]
    private var activeID: UUID?
    private(set) var worker: Task<Void, Never>?

    func enqueue(_ papers: [Paper]) {
        for paper in papers { pending[paper.id] = paper }
        start()
    }

    func discard(_ id: UUID) async {
        pending[id] = nil
        if activeID == id {
            worker?.cancel()
            worker = nil
            activeID = nil
        }
        await index.discard(id)
        start()
    }

    private func start() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self, index] in
            while !Task.isCancelled, let paper = self?.pending.popFirst()?.value {
                self?.activeID = paper.id
                try? await index.prepareIfAbsent(paper)
            }
            if !Task.isCancelled {
                self?.activeID = nil
                self?.worker = nil
            }
        }
    }

    deinit { worker?.cancel() }
}
