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
    var usesReflowMargin = false
}

struct PDFInlineNote: Equatable {
    let id: UUID
    let anchors: [NoteAnchor]
    let color: AnnotationColor?
    var style: AnnotationStyle? = nil
}

protocol PDFStrokeLocating: Sendable {
    func historicalInk(_ marks: [Highlight], in url: URL) async throws -> (
        anchors: [UUID: [NoteAnchor]], strokes: [UUID: [NoteAnchor]]
    )
    func anchors(forStroke marks: [Highlight], in url: URL) async throws -> [NoteAnchor]
}

extension PDFReadingNoteLocator: PDFStrokeLocating {}

extension ReaderModel {
    var reflowInlinePDFNotes: [PDFInlineNote] {
        guard let paper = currentEdition else { return [] }
        let version = paper.digest + ":original-0"
        let local = inlineReadingNotes.reversed().filter {
            $0.contentVersion == version && $0.anchors.first?.readingPageIndex != nil
        }
        let ordered = local.filter { $0.dimension == nil } + local.filter { $0.dimension != nil }
        let historical =
            ordered.contains { $0.legacyStrokeMemberID != nil }
            ? Dictionary(grouping: pdfBilingual.historicalHighlights(in: self), by: \.pageIndex) : [:]
        return ordered.map { note in
            let restored = note.legacyStrokeMemberID.flatMap { member -> [NoteAnchor]? in
                guard let anchor = note.anchors.first, let page = anchor.pdfPageIndex,
                    let scope = pdfBilingual.verifiedStroke(
                        containing: member, page: page, marks: historical[page] ?? []),
                    scope.contains(anchor)
                else { return nil }
                return scope
            }
            return PDFInlineNote(id: note.id, anchors: restored ?? note.anchors, color: note.dimension?.color)
        }
    }

    /// PDFKit draws one hit target per range. The margin reader can present each overlapping note.
    var inlinePDFNotes: [PDFInlineNote] {
        var seen = Set<[NoteAnchor]>()
        return reflowInlinePDFNotes.filter { seen.insert($0.anchors).inserted }
    }

    var inlinePDFHighlights: [PDFInlineNote] {
        currentHighlights.compactMap { mark in
            let anchors = mark.pdfReadingAnchor.map { [$0] } ?? pdfBilingual.verifiedAnchors(for: mark)
            guard !anchors.isEmpty else { return nil }
            return PDFInlineNote(id: mark.id, anchors: anchors, color: mark.color, style: mark.style)
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

    /// Capture the click on the main actor before starting layout or I/O. A newer click or dismissal owns the editor.
    @discardableResult
    func openPDFHighlightNote(
        _ mark: Highlight, inReflow: Bool = false, locator: any PDFStrokeLocating = PDFReadingNoteLocator()
    ) -> Task<Void, Never>? {
        guard let paper, mark.paperID == paper.id, mode == "original", currentHighlights.contains(mark) else {
            return nil
        }
        let request = UUID()
        pendingPDFNoteRequest = request
        let stroke = mark.strokeID.map { id in currentHighlights.filter { $0.strokeID == id } } ?? [mark]
        if mark.pdfTranslationTarget != nil {
            let anchors = stroke.compactMap(\.pdfReadingAnchor)
            guard anchors.count == stroke.count else { return nil }
            if let existing = mark.legacyPDFTranslationNote(
                in: inlineReadingNotes, contentVersion: paper.digest + ":original-0")
            {
                pdfNoteEditor = PDFNoteEditorSession(note: existing, marks: [], usesReflowMargin: inReflow)
                return nil
            }
            openPDFNote(anchors, in: paper, inReflow: inReflow)
            return nil
        }
        return Task {
            guard pendingPDFNoteRequest == request else { return }
            do {
                let url = root.appendingPathComponent(paper.originalPath)
                let historical =
                    mark.strokeID == nil && mark.pdfTextStart != nil
                    ? currentHighlights.filter { $0.pageIndex == mark.pageIndex && $0.isHistoricalPDFInk } : []
                let recovered: [NoteAnchor]?
                if historical.isEmpty {
                    recovered = nil
                } else if let cached = pdfBilingual.verifiedStroke(
                    containing: mark.id, page: mark.pageIndex, marks: historical)
                {
                    recovered = cached
                } else {
                    recovered = try await locator.historicalInk(historical, in: url).strokes[mark.id]
                }
                var scope = recovered
                if let recovered {
                    // Distinct existing notes keep their separate scopes, even on adjacent old ink.
                    let attached = inlineReadingNotes.filter { note in
                        note.contentVersion == paper.digest + ":original-0"
                            && note.anchors.contains(where: recovered.contains)
                    }
                    if attached.count > 1 || attached.first.map({ $0.legacyStrokeMemberID == nil }) == true {
                        scope = nil
                    }
                }
                let anchors: [NoteAnchor]
                if let scope {
                    anchors = scope
                } else {
                    anchors = try await locator.anchors(forStroke: stroke, in: url)
                }
                guard pendingPDFNoteRequest == request, selectedPaperID == paper.id, mode == "original",
                    !inReflow || pdfBilingual.isOpen
                else { return }
                let current = currentHighlights
                if let id = mark.strokeID {
                    guard current.filter({ $0.strokeID == id }) == stroke else { return }
                } else {
                    guard current.contains(mark),
                        scope == nil
                            || current.filter({ $0.pageIndex == mark.pageIndex && $0.isHistoricalPDFInk }) == historical
                    else { return }
                }
                openPDFNote(anchors, in: paper, inReflow: inReflow, restoredStroke: scope != nil)
            } catch {
                if pendingPDFNoteRequest == request && selectedPaperID == paper.id {
                    message = error.localizedDescription
                }
            }
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

        var inReflow: Bool {
            if case .original = self { return false }
            return true
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
        let request = action == .note ? UUID() : nil
        if let request { pendingPDFNoteRequest = request }
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
                    guard pendingPDFNoteRequest == request else { return }
                    let strokeID = UUID()
                    let ink: [Highlight] =
                        selection.inReflow
                        ? []
                        : fragments.map {
                            var mark = $0.highlight(for: paper.id)
                            mark.strokeID = strokeID
                            return mark
                        }
                    openPDFNote(anchors, in: paper, inReflow: selection.inReflow, marks: ink)
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

    private func openPDFNote(
        _ anchors: [NoteAnchor], in paper: Paper, inReflow: Bool, marks: [Highlight] = [], restoredStroke: Bool = false
    ) {
        guard !anchors.isEmpty else { return }
        let passage = Self.contiguousPDFSpans(anchors)
        let chosen = inlinePDFNotes.first(where: { Self.contiguousPDFSpans($0.anchors) == passage })?.id
        let existing =
            currentReadingNotes.first { $0.id == chosen }
            ?? (restoredStroke
                ? inlineReadingNotes.first {
                    $0.contentVersion == paper.digest + ":original-0" && $0.legacyStrokeMemberID != nil
                        && $0.anchors.count == 1
                        && anchors.contains($0.anchors[0])
                } : nil)
        if let existing {
            pdfNoteEditor = PDFNoteEditorSession(note: existing, marks: [], usesReflowMargin: inReflow)
        } else {
            let note = ReadingNote(
                paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: anchors, markdown: "")
            pdfNoteEditor = PDFNoteEditorSession(note: note, marks: marks, usesReflowMargin: inReflow)
        }
    }

    /// The same verified characters may be one PDFKit run or several reflow runs.
    private static func contiguousPDFSpans(_ anchors: [NoteAnchor]) -> [NoteAnchor] {
        var result: [NoteAnchor] = []
        for anchor in anchors {
            if let previous = result.last, previous.key == anchor.key, previous.target == anchor.target,
                previous.end == anchor.start
            {
                let index = result.count - 1
                result[index].end = anchor.end
                result[index].text += anchor.text
            } else {
                result.append(anchor)
            }
        }
        return result
    }

    func openReflowMarginNote(_ id: UUID) {
        guard pdfBilingual.isOpen, let paper, let note = inlineReadingNotes.first(where: { $0.id == id }),
            note.contentVersion == paper.digest + ":original-0", note.anchors.first?.readingPageIndex != nil
        else { return }
        pdfNoteEditor = PDFNoteEditorSession(note: note, marks: [], usesReflowMargin: true)
    }

    /// A saved quote stays editable even when its original text cannot be located on this reflow.
    func useOriginalPDFNoteCard(for id: UUID) {
        guard pdfNoteEditor?.id == id, pdfNoteEditor?.usesReflowMargin == true else { return }
        pdfNoteEditor?.usesReflowMargin = false
    }

    func closePDFReadingNote() {
        pdfNoteEditor = nil
        requestedReadingNote = nil
        Task { await flushReadingNotes() }
    }
}
