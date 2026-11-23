import Foundation
import PaperReaderKit

struct PDFNoteEditorSession: Identifiable {
    var id: UUID { note.id }
    let note: ReadingNote
    let marks: [Highlight]
}

extension ReaderModel {
    var hasPDFNoteSelection: Bool {
        !selectedPDFNoteRanges.isEmpty
    }

    private var selectedPDFNoteRanges: [Int: [NSRange]] {
        guard mode == "original", !pdfSelectionSpansPages else { return [:] }
        if !selectionText.isEmpty, !pdfSelectionRanges.isEmpty { return [selectionPage: pdfSelectionRanges] }
        return Dictionary(grouping: pdfBilingual.selectedSourceSentences, by: \.pageIndex)
            .mapValues { $0.flatMap(\.characterRanges) }
    }

    func beginPDFReadingNote() async {
        let requested = selectedPDFNoteRanges
        guard !requested.isEmpty, let paper else { return }
        let url = root.appendingPathComponent(paper.originalPath)
        let locator = PDFReadingNoteLocator()
        do {
            var fragments: [PDFReadingNoteFragment] = []
            for page in requested.keys.sorted() {
                fragments += try await locator.selected(ranges: requested[page] ?? [], pageIndex: page, in: url)
            }
            guard selectedPaperID == paper.id, selectedPDFNoteRanges == requested, !fragments.isEmpty else { return }
            let anchors = fragments.map(\.anchor)
            if let existing = currentReadingNotes.first(where: { $0.anchors == anchors }) {
                pdfNoteEditor = PDFNoteEditorSession(note: existing, marks: [])
            } else {
                let note = ReadingNote(
                    paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: anchors, markdown: "")
                pdfNoteEditor = PDFNoteEditorSession(note: note, marks: fragments.map { $0.highlight(for: paper.id) })
            }
        } catch {
            guard selectedPaperID == paper.id, selectedPDFNoteRanges == requested else { return }
            message = error.localizedDescription
        }
    }

    func closePDFReadingNote() {
        pdfNoteEditor = nil
        requestedReadingNote = nil
        Task { await flushReadingNotes() }
    }
}
