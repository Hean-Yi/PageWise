import Foundation
import PaperReaderKit

struct PDFReflowTextSelection: Equatable, Sendable {
    let sentence: PDFSourceSentence
    let language: String
    let range: NSRange
    let text: String
}

enum PDFReflowSelectionAction: String, Sendable {
    case note, highlight, bookmark
}

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
        let local = inlineReadingNotes.reversed().filter {
            $0.contentVersion == version && $0.anchors.first?.pdfPageIndex != nil
        }
        let ordered = local.filter { $0.dimension == nil } + local.filter { $0.dimension != nil }
        var seen = Set<[NoteAnchor]>()
        return ordered.compactMap {
            guard seen.insert($0.anchors).inserted else { return nil }
            return PDFInlineNote(id: $0.id, anchors: $0.anchors, color: $0.dimension?.color)
        }
    }

    var inlinePDFHighlights: [PDFInlineNote] {
        currentHighlights.compactMap { mark in
            guard let start = mark.pdfTextStart, start >= 0, mark.pageKey == "original-\(mark.pageIndex)",
                !mark.text.isEmpty, start <= Int.max - mark.text.utf16.count
            else { return nil }
            let anchor = NoteAnchor(
                key: mark.pageKey, target: "pdf", text: mark.text, start: start, end: start + mark.text.utf16.count)
            return PDFInlineNote(id: mark.id, anchors: [anchor], color: mark.color)
        }
    }

    var hasPDFNoteSelection: Bool {
        mode == "original"
            && ((!pdfSelectionSpansPages && !selectionText.isEmpty && !pdfSelectionRanges.isEmpty)
                || (pdfBilingual.isOpen && !pdfBilingual.reflowTextSelection.isEmpty))
    }

    func beginPDFReadingNote() async {
        guard hasPDFNoteSelection, let paper else { return }
        if pdfBilingual.isOpen, !pdfBilingual.reflowTextSelection.isEmpty {
            await performReflowSelectionAction(.note, selection: pdfBilingual.reflowTextSelection)
            return
        }
        let ranges = pdfSelectionRanges
        let page = selectionPage
        let url = root.appendingPathComponent(paper.originalPath)
        func isCurrent() -> Bool {
            selectedPaperID == paper.id && mode == "original" && selectionPage == page && pdfSelectionRanges == ranges
        }
        do {
            let fragments = try await PDFReadingNoteLocator().selected(ranges: ranges, pageIndex: page, in: url)
            if isCurrent() { openPDFNote(fragments, in: paper) }
        } catch {
            if isCurrent() { message = error.localizedDescription }
        }
    }

    func performReflowSelectionAction(_ action: PDFReflowSelectionAction, selection: [PDFReflowTextSelection]) async {
        guard let paper, !selection.isEmpty, pdfBilingual.matches(self) else { return }
        let pieces = selection.compactMap { piece in
            pdfBilingual.sourceRange(for: piece).map { (sentence: piece.sentence, range: $0) }
        }
        guard pieces.count == selection.count else { return }
        if action == .bookmark {
            let page = pieces[0].sentence.pageIndex
            let key = "original-\(page)"
            guard pageKeys.indices.contains(page), pageKeys[page] == key,
                !currentBookmarks.contains(where: { $0.pageKey == key })
            else { return }
            state.bookmarks.append(PageBookmark(paperID: paper.id, pageKey: key, pageIndex: page, mode: mode))
            workspaceRevision += 1
            scheduleWorkspaceSave(immediately: true)
            return
        }
        let url = root.appendingPathComponent(paper.originalPath)
        func isCurrent() -> Bool {
            selectedPaperID == paper.id && pdfBilingual.matches(self)
                && (pdfBilingual.reflowTextSelection.isEmpty || pdfBilingual.reflowTextSelection == selection)
        }
        do {
            let fragments = try await PDFReadingNoteLocator().selected(pieces, in: url)
            guard isCurrent() else { return }
            if action == .note {
                openPDFNote(fragments, in: paper)
            } else {
                var existing = Set(inlinePDFHighlights.flatMap(\.anchors))
                let newMarks = fragments.filter { existing.insert($0.anchor).inserted }.map { fragment in
                    var mark = fragment.highlight(for: paper.id)
                    mark.pdfTextStart = fragment.anchor.start
                    return mark
                }
                guard !newMarks.isEmpty else { return }
                state.highlights.append(contentsOf: newMarks)
                await save()
            }
        } catch {
            if isCurrent() { message = error.localizedDescription }
        }
    }

    private func openPDFNote(_ fragments: [PDFReadingNoteFragment], in paper: Paper) {
        guard !fragments.isEmpty else { return }
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
    }

    func closePDFReadingNote() {
        pdfNoteEditor = nil
        requestedReadingNote = nil
        Task { await flushReadingNotes() }
    }
}
