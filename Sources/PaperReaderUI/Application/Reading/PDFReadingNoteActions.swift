import Foundation
import PaperReaderKit

struct PDFReflowTextSelection: Equatable, Sendable {
    let sentence: PDFSourceSentence
    let language: String
    let range: NSRange
    let text: String
}

enum PDFReflowSelectionAction: Equatable, Sendable {
    case note, bookmark
    case mark(color: AnnotationColor, style: AnnotationStyle, removing: Bool)
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
    var style: AnnotationStyle? = nil
}

extension ReaderModel {
    /// A report indexes its paragraph notes in the sidebar. Give an existing ordinary note the first hit in the text.
    var inlinePDFNotes: [PDFInlineNote] {
        guard let paper = currentEdition else { return [] }
        let version = paper.digest + ":original-0"
        let local = inlineReadingNotes.reversed().filter {
            $0.contentVersion == version && $0.anchors.first?.readingPageIndex != nil
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
            guard let anchor = mark.pdfReadingAnchor else { return nil }
            return PDFInlineNote(id: mark.id, anchors: [anchor], color: mark.color, style: mark.style)
        }
    }

    var hasPDFNoteSelection: Bool {
        mode == "original"
            && ((!pdfSelectionSpansPages && !selectionText.isEmpty && !pdfSelectionRanges.isEmpty)
                || (pdfBilingual.isOpen && !pdfBilingual.reflowTextSelection.isEmpty))
    }

    func beginPDFReadingNote() async {
        if pdfBilingual.isOpen, !pdfBilingual.reflowTextSelection.isEmpty {
            await performReflowSelectionAction(.note, selection: pdfBilingual.reflowTextSelection)
        } else {
            await performPDFSelectionAction(.note)
        }
    }

    func performPDFSelectionAction(_ action: PDFReflowSelectionAction) async {
        guard mode == "original", let paper, !pdfSelectionSpansPages, !pdfSelectionRanges.isEmpty,
            !selectionText.isEmpty
        else { return }
        await perform(action, selection: .original(selectionPage, pdfSelectionRanges), paper: paper)
    }

    func performReflowSelectionAction(_ action: PDFReflowSelectionAction, selection: [PDFReflowTextSelection]) async {
        guard let paper, let first = selection.first, pdfBilingual.matches(self),
            selection.allSatisfy({ $0.language == first.language && pdfBilingual.validatedText(for: $0) != nil })
        else { return }
        if first.language == "zh" {
            let anchors = selection.compactMap { piece -> NoteAnchor? in
                guard let text = pdfBilingual.validatedText(for: piece) else { return nil }
                return NoteAnchor(
                    key: "original-\(piece.sentence.pageIndex)",
                    target: NoteAnchor.pdfTranslationTarget(sentenceID: piece.sentence.id, translation: text),
                    text: piece.text, start: piece.range.location, end: NSMaxRange(piece.range))
            }
            await perform(action, selection: .translation(anchors), paper: paper)
        } else {
            await perform(action, selection: .reflow(selection), paper: paper)
        }
    }

    func pdfSelectionAppearance() async -> PDFAnnotationAppearance {
        guard let paper, mode == "original", !pdfSelectionSpansPages, !pdfSelectionRanges.isEmpty else {
            return .init()
        }
        let url = root.appendingPathComponent(paper.originalPath)
        let locator = PDFReadingNoteLocator()
        do {
            let fragments = try await locator.selected(ranges: pdfSelectionRanges, pageIndex: selectionPage, in: url)
            return try await locator.appearance(
                for: fragments, in: currentHighlights, paperID: paper.id, documentURL: url)
        } catch { return .init() }
    }

    func openPDFHighlightNote(_ mark: Highlight) async {
        guard let paper, mark.paperID == paper.id, mode == "original", currentHighlights.contains(mark) else { return }
        if let anchor = mark.pdfReadingAnchor, anchor.pdfTranslationPageIndex != nil {
            openPDFNote([anchor], in: paper)
            return
        }
        do {
            let parts = try await PDFReadingNoteLocator().locatedHighlight(
                mark, in: root.appendingPathComponent(paper.originalPath))
            guard selectedPaperID == paper.id, mode == "original", currentHighlights.contains(mark) else { return }
            openPDFNote(parts.map(\.anchor), in: paper)
        } catch {
            if selectedPaperID == paper.id { message = error.localizedDescription }
        }
    }

    private enum Passage {
        case original(Int, [NSRange])
        case reflow([PDFReflowTextSelection])
        case translation([NoteAnchor])

        var page: Int? {
            switch self {
            case .original(let page, _): page
            case .reflow(let pieces): pieces.first?.sentence.pageIndex
            case .translation(let anchors): anchors.first?.pdfTranslationPageIndex
            }
        }

        func fragments(in url: URL, using locator: PDFReadingNoteLocator) async throws -> [PDFReadingNoteFragment] {
            switch self {
            case .original(let page, let spans): try await locator.selected(ranges: spans, pageIndex: page, in: url)
            case .reflow(let pieces): try await locator.selected(pieces.map { ($0.sentence, $0.range) }, in: url)
            case .translation: []
            }
        }
    }

    private func perform(_ action: PDFReflowSelectionAction, selection: Passage, paper: Paper) async {
        guard let page = selection.page, pageKeys.indices.contains(page), pageKeys[page] == "original-\(page)" else {
            return
        }
        let key = pageKeys[page]
        if action == .bookmark {
            guard !currentBookmarks.contains(where: { $0.pageKey == key }) else { return }
            state.bookmarks.append(PageBookmark(paperID: paper.id, pageKey: key, pageIndex: page, mode: mode))
            workspaceRevision += 1
            scheduleWorkspaceSave(immediately: true)
            return
        }
        let url = root.appendingPathComponent(paper.originalPath)
        let locator = PDFReadingNoteLocator()
        func isCurrent() -> Bool {
            guard selectedPaperID == paper.id, mode == "original" else { return false }
            switch selection {
            case .original(let page, let spans):
                return selectionPage == page && pdfSelectionRanges == spans && !pdfSelectionSpansPages
            case .reflow, .translation: return pdfBilingual.isOpen
            }
        }

        // Resolve quick successive palette clicks in the same order as the reader applied them.
        let previous = pdfInkEdit
        let task = Task {
            await previous?.value
            guard isCurrent() else { return }
            do {
                let fragments = try await selection.fragments(in: url, using: locator)
                guard isCurrent() else { return }
                let anchors: [NoteAnchor]
                if case .translation(let translated) = selection {
                    anchors = translated
                } else {
                    anchors = fragments.map(\.anchor)
                }
                if case .note = action {
                    openPDFNote(anchors, in: paper, marks: fragments.map { $0.highlight(for: paper.id) })
                    return
                }
                guard case .mark(let color, let style, let removing) = action else { return }
                if case .translation = selection {
                    let selected = anchors.compactMap { anchor -> Highlight? in
                        guard let page = anchor.pdfTranslationPageIndex else { return nil }
                        var mark = Highlight(
                            paperID: paper.id, pageKey: anchor.key, pageIndex: page, text: anchor.text, rects: [])
                        mark.pdfTranslationTarget = anchor.target
                        mark.contentVersion = paper.digest + ":original-0"
                        mark.textRange = [anchor.start, anchor.end]
                        return mark
                    }
                    state.highlights = AnnotationRangeEditor.applying(
                        selected, to: state.highlights, color: color, style: style, removing: removing)
                } else {
                    // Other note editors and the Agent may also change ink while PDFKit resolves its geometry.
                    while isCurrent() {
                        let before = state.highlights
                        let edited = try await locator.applying(
                            fragments, to: before, paperID: paper.id, color: color, style: style, removing: removing,
                            in: url)
                        guard isCurrent() else { return }
                        if state.highlights != before { continue }
                        if edited == before { return }
                        state.highlights = edited
                        break
                    }
                }
                _ = await save()
            } catch {
                if isCurrent() { message = error.localizedDescription }
            }
        }
        pdfInkEdit = task
        await task.value
    }

    private func openPDFNote(_ anchors: [NoteAnchor], in paper: Paper, marks: [Highlight] = []) {
        guard !anchors.isEmpty else { return }
        if let chosen = inlinePDFNotes.first(where: { $0.anchors == anchors }),
            let existing = currentReadingNotes.first(where: { $0.id == chosen.id })
        {
            pdfNoteEditor = PDFNoteEditorSession(note: existing, marks: [])
        } else {
            let note = ReadingNote(
                paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: anchors, markdown: "")
            pdfNoteEditor = PDFNoteEditorSession(note: note, marks: marks)
        }
    }

    func closePDFReadingNote() {
        pdfNoteEditor = nil
        requestedReadingNote = nil
        Task { await flushReadingNotes() }
    }
}
