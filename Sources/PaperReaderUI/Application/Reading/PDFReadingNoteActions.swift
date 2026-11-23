import Foundation
import PaperReaderKit

struct PDFNoteEditorSession: Identifiable {
    var id: UUID { note.id }
    let note: ReadingNote
    let marks: [Highlight]
}

struct PDFInlineNote: Equatable {
    let id: UUID
    let anchors: [NoteAnchor]
    let color: AnnotationColor?
}

extension ReaderModel {
    /// A report indexes its paragraph notes in the sidebar. Give an existing ordinary note the first hit in the text.
    var inlinePDFNotes: [PDFInlineNote] {
        guard let paper = currentEdition else { return [] }
        let version = paper.digest + ":original-0"
        let summaries = Set(
            state.chats.compactMap { turn in
                turn.paperID == paper.id && turn.closeReadingVersion != nil ? turn.readingNoteID : nil
            })
        let local = currentReadingNotes.reversed().filter {
            $0.contentVersion == version && $0.anchors.first?.pdfPageIndex != nil && !summaries.contains($0.id)
        }
        let ordered = local.filter { $0.dimension == nil } + local.filter { $0.dimension != nil }
        var seen = Set<[NoteAnchor]>()
        return ordered.compactMap {
            guard seen.insert($0.anchors).inserted else { return nil }
            return PDFInlineNote(id: $0.id, anchors: $0.anchors, color: $0.dimension?.color)
        }
    }

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
            if let chosen = inlinePDFNotes.first(where: { $0.anchors == anchors }),
                let existing = currentReadingNotes.first(where: { $0.id == chosen.id })
            {
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
