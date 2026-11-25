import Foundation
import PaperReaderKit

extension ReaderModel {
    func prepareImportedAbstract(for id: UUID) async {
        guard let paper = state.papers.first(where: { $0.id == id }), !Task.isCancelled else { return }
        // A delayed or unreadable file can be retried on the next load without rolling back the import.
        try? await previewReader.prepare(paper: paper, root: root)
    }

    func backfillLibraryAbstracts() {
        guard !state.papers.isEmpty else { return }
        abstractBackfill?.cancel()
        abstractBackfill = Task(priority: .utility) { [papers = state.papers, previewReader, root] in
            for paper in papers {
                guard !Task.isCancelled else { return }
                try? await previewReader.prepare(paper: paper, root: root)
            }
        }
    }

    public func previewContent(for paperID: UUID) async -> PaperPreviewContent {
        guard let paper = state.papers.first(where: { $0.id == paperID }), !Task.isCancelled else { return .init() }
        var content =
            (try? await previewReader.read(paper: paper, root: root, store: pdfTranslations, settings: modelSettings))
            ?? .init()
        guard !Task.isCancelled else { return .init() }
        content.oneSentence = closeReadingTakeaway(for: paper)
        return content
    }

    private func closeReadingTakeaway(for paper: Paper) -> String? {
        guard let report = state.chats.last(where: { $0.paperID == paper.id && $0.closeReadingVersion != nil }) else {
            return nil
        }
        if let id = report.readingNoteID,
            let note = state.readingNotes.first(where: { $0.id == id && $0.paperID == paper.id && $0.deletedAt == nil }
            ),
            let sentence = PreviewTakeaway.fromNotebook(note.markdown)
        {
            return sentence
        }
        // Older close readings kept their thesis as an anchored margin note.
        let ids = Set(report.closeReadingNoteIDs ?? [])
        for note in state.readingNotes
        where ids.contains(note.id) && note.paperID == paper.id && note.deletedAt == nil
            && note.dimension == .thesis
        {
            if let sentence = PreviewTakeaway.firstSentence(in: note.markdown) { return sentence }
        }
        return nil
    }
}
