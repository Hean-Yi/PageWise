import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func deletePaper(_ id: UUID) async -> Bool {
        guard let paper = state.papers.first(where: { $0.id == id }) else {
            message = "这篇论文已不在书库中。"
            return false
        }
        let wasReading = readingPaper == id
        guard await save(deletingPaper: id) else {
            if wasReading, selectedPaperID == id { beginReading() }
            return false
        }
        status = "已删除《\(paper.title)》"
        return true
    }

    func wasPaperDeleted(since date: Date, digest: String, publicationID: String?) -> Bool {
        if let deletion = deletedDigests[digest], deletion >= date { return true }
        return publicationID.flatMap { deletedPublications[$0] }.map { $0 >= date } ?? false
    }

    func didDeletePaper(_ paper: Paper) {
        let id = paper.id
        let date = Date()
        lastPaperDeletion[id] = date
        deletedDigests[paper.digest] = date
        for link in [paper.sourceURL, paper.onlineSource?.candidateID].compactMap({ $0 })
            + (paper.linkedPublicationURLs ?? [])
        {
            deletedPublications[link] = date
        }
        translationTasks[id]?.cancel()
        pausedReflows.remove(id)
        reflowStages[id] = nil
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

    func removeDeletedFiles(_ paper: Paper) async {
        let worker = translationTasks[paper.id]
        await previewReader.discard(paper: paper, root: root)
        if !state.papers.contains(where: { $0.digest == paper.digest }) {
            await pdfTranslations.invalidatePendingWrites(documentHash: paper.digest)
        }
        do {
            try await store.finishFileRemoval(
                id: paper.id, digest: paper.digest,
                keepDigest: state.papers.contains { $0.digest == paper.digest }, retireMarker: worker == nil)
            if let worker {
                // A renderer can still hold an open file while it unwinds. Sweep its UUID once more.
                Task {
                    await worker.value
                    do {
                        try await store.finishFileRemoval(id: paper.id, digest: paper.digest, keepDigest: true)
                    } catch { message = "论文记录已删除，应用内文件将在下次启动时继续清理。" }
                }
            }
        } catch { message = "论文记录已删除，应用内文件将在下次启动时继续清理。" }
    }
}
