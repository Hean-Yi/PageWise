import Foundation
import PaperReaderKit

extension ReaderModel {
    public func updateMemory(id: UUID, text: String) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }),
            state.memories[index].correct(to: text)
        else { return }
        Task { await save() }
    }
    public func deleteMemory(_ id: UUID) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }),
            state.memories[index].forget()
        else { return }
        Task { await save() }
    }

    /// A reading/translation observation creates one paper-grounded memory. The reader can
    /// delete it; a deleted paper memory is a tombstone and must not be recreated.
    func ensurePaperMemory(paperID: UUID) async {
        guard let paper = state.papers.first(where: { $0.id == paperID }),
            !state.memories.contains(where: { memory in
                if case .paper(let source) = memory.librarySource { return source == paperID }
                return false
            })
        else { return }
        var statement = "读过《" + String(paper.displayTitle.prefix(160)) + "》"
        let summary =
            paper.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? paper.onlineSource?.abstractText?.trimmingCharacters(in: .whitespacesAndNewlines) : paper.summary
        if let summary, !summary.isEmpty {
            statement += "：" + String(summary.prefix(220))
        }
        state.memories.append(MemoryItem(paperID: paperID, statement: statement))
        await save()
    }
}
