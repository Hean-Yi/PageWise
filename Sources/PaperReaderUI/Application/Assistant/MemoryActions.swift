import Foundation
import PaperReaderKit

extension ReaderModel {
    public func updateMemory(id: UUID, text: String) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }) else { return }
        state.memories[index].text = text
        state.memories[index].userEdited = true
        Task { await save() }
    }
    public func deleteMemory(_ id: UUID) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }) else { return }
        state.memories[index].text = ""
        state.memories[index].deleted = true
        Task { await save() }
    }
}
