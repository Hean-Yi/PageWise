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
}
