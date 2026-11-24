import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func trashPaper(_ id: UUID) async -> Bool {
        guard let title = state.papers.first(where: { $0.id == id })?.title else {
            message = "这篇论文已不在书库中。"
            return false
        }
        let wasReading = readingPaper == id
        guard await save(paperTrashChange: .trash(id, at: Date())) else {
            if wasReading, selectedPaperID == id { beginReading() }
            return false
        }
        status = "已将《\(title)》移到最近删除"
        return true
    }

    @discardableResult public func restorePaper(_ id: UUID) async -> Bool {
        guard let archived = state.trashedPapers.first(where: { $0.id == id }) else {
            message = "找不到要恢复的论文。"
            return false
        }
        guard await save(paperTrashChange: .restore(id, deletedAt: archived.deletedAt)) else { return false }
        status = "已恢复《\(archived.paper.title)》"
        return true
    }

    /// Runs after SQLite commits, before moving the live records into the trash.
    func didTrashPaper(_ id: UUID, at date: Date) {
        lastPaperDeletion[id] = date
        translationTasks[id]?.cancel()
        pdfDocumentTranslation.discard(id)
        if closeReadingPaperID == id { closeReadingTask?.cancel() }
        if assistantDraft?.paperID == id { assistantDraft = nil }
        if translationDraft?.paperID == id { translationDraft = nil }
        if let note = lastDeletedNoteID, state.readingNotes.contains(where: { $0.id == note && $0.paperID == id }) {
            lastDeletedNoteID = nil
        }
        if selectedPaperID == id {
            notePassageSheet = nil
            returnFromReader()
        }
    }
}
