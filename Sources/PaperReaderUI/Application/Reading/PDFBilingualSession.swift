import CryptoKit
import Foundation
import Observation
import PaperReaderKit

/// A loaded original page as presented in the continuous paragraph reader.
struct PDFParagraphPage: Equatable {
    let index: Int
    let sentences: [PDFSourceSentence]
    var translations: [String: String]
    let illustrations: [PDFReadingIllustration]
    let notice: String?
}

@MainActor @Observable
final class PDFBilingualSession {
    private(set) var isOpen = false
    private(set) var sentences: [PDFSourceSentence] = []
    private(set) var paragraphSentences: [PDFSourceSentence] = []
    private(set) var illustrations: [PDFReadingIllustration] = []
    private(set) var sourceIllustration: PDFReadingIllustration?
    private(set) var translations: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var isTranslating = false
    private(set) var notice: String?
    private(set) var error: String?
    var reflowTextSelection: [PDFReflowTextSelection] = []
    private(set) var translationSelectedIDs: [String] = []
    private(set) var selectionRequestRevision = 0
    private(set) var selectionSource: String?
    private(set) var selectionTranslation: String?
    // Page data is local and bounded. Only the explicit paragraph entry authorizes the translation job.
    private var paragraphLayout = false
    private var readingParagraphs = false
    private var paperID: UUID?
    private(set) var pageIndex = -1
    private(set) var paragraphJumpPage = 0
    private(set) var paragraphJumpRevision = 0
    private(set) var paragraphJumpItem: PaperNavigationItem?
    private struct LoadedPage {
        let originalSentences: [PDFSourceSentence]
        let originalNotice: String?
        var paragraph: PDFParagraphPage
    }
    private var loadedPages: [Int: LoadedPage] = [:]
    var paragraphPages: [Int: PDFParagraphPage] { loadedPages.mapValues(\.paragraph) }
    private struct HistoricalInkPage {
        let marks: [Highlight]
        let geometry: [UUID: (mark: Highlight, anchors: [NoteAnchor])]
        let strokes: [UUID: [NoteAnchor]]
    }

    private var historicalPages: [Int: HistoricalInkPage] = [:]

    func historicalHighlights(in model: ReaderModel) -> [Highlight] {
        guard isOpen, paperID == model.selectedPaperID else { return [] }
        let pages = Set(
            model.inlineReadingNotes.compactMap { note in
                note.legacyStrokeMemberID == nil ? nil : note.anchors.first?.pdfPageIndex
            })
        return model.currentHighlights.filter { mark in
            loadedPages[mark.pageIndex] != nil
                && (mark.hasOnlyOriginalPDFGeometry || pages.contains(mark.pageIndex) && mark.isHistoricalPDFInk)
        }
    }

    func verifiedAnchors(for mark: Highlight) -> [NoteAnchor] {
        guard let cached = historicalPages[mark.pageIndex]?.geometry[mark.id], cached.mark == mark else { return [] }
        return cached.anchors
    }

    func verifiedStroke(containing id: UUID, page: Int, marks: [Highlight]) -> [NoteAnchor]? {
        guard let cached = historicalPages[page], let anchors = cached.strokes[id], cached.marks == marks else {
            return nil
        }
        return anchors
    }

    func locateHistoricalInk(_ marks: [Highlight], model: ReaderModel) async {
        guard !Task.isCancelled, isOpen, let paper = model.paper, paper.id == paperID else { return }
        let byPage = Dictionary(grouping: marks, by: \.pageIndex)
        historicalPages = historicalPages.filter { byPage[$0.key] != nil }
        let pending = byPage.filter { historicalPages[$0.key]?.marks != $0.value }
        guard !pending.isEmpty else { return }
        let url = model.root.appendingPathComponent(paper.originalPath)
        guard let projection = try? await PDFReadingNoteLocator().historicalInk(pending.values.flatMap { $0 }, in: url),
            !Task.isCancelled, isOpen, paperID == paper.id
        else { return }
        let current = Dictionary(grouping: historicalHighlights(in: model), by: \.pageIndex)
        for (page, batch) in pending where current[page] == batch {
            var geometry: [UUID: (mark: Highlight, anchors: [NoteAnchor])] = [:]
            var strokes: [UUID: [NoteAnchor]] = [:]
            for mark in batch {
                if let anchors = projection.anchors[mark.id] { geometry[mark.id] = (mark, anchors) }
                strokes[mark.id] = projection.strokes[mark.id]
            }
            historicalPages[page] = HistoricalInkPage(marks: batch, geometry: geometry, strokes: strokes)
        }
    }

    var selectedSourceSentences: [PDFSourceSentence] {
        guard isOpen, !translationSelectedIDs.isEmpty else { return [] }
        let selected = Set(translationSelectedIDs)
        return loadedPages.keys.sorted().flatMap { index in
            loadedPages[index]?.originalSentences.filter { selected.contains($0.id) } ?? []
        }
    }

    @ObservationIgnored private var loadTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingTranslations: [Int: [String: String]] = [:]
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    func open(_ model: ReaderModel, translatingDocument: Bool = false) {
        guard model.mode == "original", model.currentEdition?.usesSourceReflow == false else { return }
        isOpen = true
        loadPage(model)
        if translatingDocument { setParagraphLayout(true, model: model) }
    }

    func prepareParagraphReading(_ model: ReaderModel) {
        guard matches(model), !readingParagraphs else { return }
        readingParagraphs = true
        requestParagraphJump(pageIndex)
        maintainWindow(model)
    }

    func setParagraphLayout(_ enabled: Bool, model: ReaderModel) {
        guard matches(model), let paperID = model.selectedPaperID else { return }
        paragraphLayout = enabled
        if enabled {
            prepareParagraphReading(model)
            model.pdfDocumentTranslation.start(model, paperID: paperID, page: pageIndex)
        } else {
            readingParagraphs = false
            maintainWindow(model)
        }
    }

    func resumeDocumentTranslation(_ model: ReaderModel) {
        guard matches(model), let paperID = model.selectedPaperID else { return }
        model.pdfDocumentTranslation.start(model, paperID: paperID, page: pageIndex, resuming: true)
    }

    func receiveDocumentTranslations(_ values: [String: String], paperID: UUID, page: Int) {
        guard isOpen, self.paperID == paperID else { return }
        if loadedPages[page] != nil {
            loadedPages[page]?.paragraph.translations.merge(values) { _, new in new }
        } else if loadTasks[page] != nil {
            pendingTranslations[page, default: [:]].merge(values) { _, new in new }
        }
        if pageIndex == page { translations.merge(values) { _, new in new } }
    }

    func settingsChanged(_ model: ReaderModel, previous: ModelSettings, credentialRemoved: Bool) {
        model.pdfDocumentTranslation.settingsChanged(
            model, previousSettings: previous, resumeVisible: paragraphLayout && !credentialRemoved)
        guard matches(model) else { return }
        releasePages()
        pageIndex = -1
        activatePage(model, scrolling: true)
    }

    func close() {
        isOpen = false
        reflowTextSelection = []
        paragraphLayout = false
        readingParagraphs = false
        releasePages()
        pause()
        isLoading = false
        illustrations = []
        sourceIllustration = nil
        pageIndex = -1
    }

    func loadPage(_ model: ReaderModel) {
        activatePage(model, scrolling: false)
    }

    /// The original PDF, outline and bookmarks can request the same page more than once.
    func consumeParagraphJump(_ model: ReaderModel) {
        guard readingParagraphs, isOpen, model.mode == "original", model.selectedPaperID == paperID,
            let index = model.jumpPage, model.visiblePage == index
        else { return }
        activatePage(model, scrolling: true)
        requestParagraphJump(index, item: model.jumpOutlineItem)
        model.jumpPage = nil
    }

    private func requestParagraphJump(_ index: Int, item: PaperNavigationItem? = nil) {
        paragraphJumpPage = index
        paragraphJumpItem = item
        paragraphJumpRevision &+= 1
    }

    func paragraphDidScroll(to index: Int, model: ReaderModel) {
        guard readingParagraphs, matches(model), model.jumpPage == nil, let paper = model.paper,
            (0..<paper.pageCount).contains(index), index != pageIndex
        else { return }
        model.recordVisiblePage(index)
        model.touch()
        activatePage(model, scrolling: true)
    }

    func revealParagraphIllustration(_ item: PDFReadingIllustration, model: ReaderModel) {
        paragraphDidScroll(to: item.pageIndex, model: model)
        revealIllustration(item)
    }

    func revealParagraphPage(_ index: Int, model: ReaderModel) {
        paragraphDidScroll(to: index, model: model)
        guard pageIndex == index else { return }
        sourceIllustration = nil
    }

    private func activatePage(_ model: ReaderModel, scrolling: Bool) {
        guard isOpen, model.mode == "original", let paper = model.paper else { return }
        let index = model.visiblePage
        guard paper.id != paperID || index != pageIndex else { return }
        if paper.id != paperID { releasePages() }
        pause()
        paperID = paper.id
        pageIndex = index
        translationSelectedIDs = []
        reflowTextSelection = []
        sourceIllustration = nil
        selectionSource = nil
        selectionTranslation = nil
        error = nil
        if readingParagraphs {
            // A recreated canvas opens on the visible page. An existing canvas moves only on a new revision.
            paragraphJumpPage = index
            paragraphJumpItem = nil
            if !scrolling && model.jumpPage == nil { paragraphJumpRevision &+= 1 }
        }
        show(loadedPages[index])
        maintainWindow(model)
    }

    private func show(_ page: LoadedPage?) {
        sentences = page?.originalSentences ?? []
        paragraphSentences = page?.paragraph.sentences ?? []
        illustrations = page?.paragraph.illustrations ?? []
        notice = page?.originalNotice
        translations = page?.paragraph.translations ?? pendingTranslations[pageIndex] ?? [:]
        isLoading = page == nil
    }

    /// A single neighboring page on each side is sufficient to begin scrolling in either direction.
    private func maintainWindow(_ model: ReaderModel) {
        guard let paper = model.paper, (0..<paper.pageCount).contains(pageIndex) else { return }
        let radius = readingParagraphs ? 1 : 0
        let range = max(0, pageIndex - radius)...min(paper.pageCount - 1, pageIndex + radius)
        for index in loadTasks.keys where !range.contains(index) {
            loadTasks.removeValue(forKey: index)?.cancel()
            pendingTranslations[index] = nil
        }
        for index in loadedPages.keys where !range.contains(index) { loadedPages[index] = nil }
        // Start the visible page first even when entering from the middle of a long paper.
        for index in [pageIndex] + range.filter({ $0 != pageIndex })
        where loadTasks[index] == nil && loadedPages[index] == nil {
            load(index, paper: paper, model: model)
        }
    }

    private func releasePages() {
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
        pendingTranslations.removeAll()
        loadedPages.removeAll()
        historicalPages.removeAll()
    }

    private func load(_ index: Int, paper: Paper, model: ReaderModel) {
        let url = model.root.appendingPathComponent(paper.originalPath)
        let settings = model.modelSettings
        let store = model.pdfTranslations
        let priority: TaskPriority = index == pageIndex ? .userInitiated : .utility
        loadTasks[index] = Task {
            var original: [PDFSourceSentence] = []
            var originalNotice: String?
            var paragraph = PDFParagraphPage(
                index: index, sentences: [], translations: [:], illustrations: [], notice: nil)
            do {
                let extraction = Task.detached(priority: priority) {
                    try PDFSentenceExtractor.extractPage(url: url, pageIndex: index, includingIllustrations: true)
                }
                let page = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: {
                    extraction.cancel()
                }
                try Task.checkCancellation()
                original = page.sentences
                originalNotice = page.notice
                paragraph = PDFParagraphPage(
                    index: index, sentences: page.paragraphSentences, translations: [:],
                    illustrations: page.illustrations,
                    notice: page.paragraphNotice)
                paragraph.translations = try await store.cached(
                    documentHash: paper.digest, sentences: original, settings: settings.model.isEmpty ? nil : settings)
            } catch {
                guard !Task.isCancelled else { return }
                originalNotice = error.localizedDescription
                paragraph = PDFParagraphPage(
                    index: index, sentences: paragraph.sentences, translations: [:],
                    illustrations: paragraph.illustrations, notice: error.localizedDescription)
                if pageIndex == index && !readingParagraphs { self.error = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            // A foreground request may complete while the cache actor is still reading the page.
            if let published = pendingTranslations.removeValue(forKey: index) {
                paragraph.translations.merge(published) { _, new in new }
            }
            loadTasks[index] = nil
            let loaded = LoadedPage(originalSentences: original, originalNotice: originalNotice, paragraph: paragraph)
            loadedPages[index] = loaded
            if pageIndex == index { show(loaded) }
        }
    }

    func translatePage(_ model: ReaderModel, paragraphs: Bool = false) {
        let sources = paragraphs ? paragraphSentences : sentences
        guard matches(model), !isLoading, !isTranslating, !sources.isEmpty else { return }
        selectionSource = nil
        selectionTranslation = nil
        model.recordPaperEngagement(.translated)
        translate(sources, model: model, selection: false)
    }

    func translateSelection(_ model: ReaderModel) {
        guard model.mode == "original", model.currentEdition?.usesSourceReflow == false,
            !model.pdfSelectionSpansPages, !isTranslating,
            let paper = model.paper, !model.selectionText.isEmpty, !model.selectionRects.isEmpty
        else { return }
        let text = model.selectionText
        let rects = model.selectionRects
        let page = model.selectionPage
        if page != model.visiblePage { model.navigateToPage(page) }
        open(model)
        let signature = "\(paper.digest)|\(page)|\(rects)|\(text)"
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let excerpt = PDFSourceSentence(
            id: "selection-\(digest)", text: text, pageIndex: page, rects: rects, paragraphID: "selection")
        let equivalent = sentences.first { sentence in
            sentence.text.split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace)
                && sentence.rects == rects
        }
        selectionRequestRevision &+= 1
        selectionSource = text
        selectionTranslation = nil
        translate([equivalent ?? excerpt], model: model, selection: true)
    }

    func dismissSelection() {
        if selectionSource != nil, isTranslating { pause() }
        selectionSource = nil
        selectionTranslation = nil
    }

    func pause() {
        translationTask?.cancel()
        translationTask = nil
        requestID = UUID()
        isTranslating = false
    }

    func revealIllustration(_ item: PDFReadingIllustration) {
        guard isOpen, item.pageIndex == pageIndex, illustrations.contains(where: { $0.id == item.id }) else { return }
        sourceIllustration = item
    }

    func selectFromTranslation(_ ids: [String]) {
        if ids.isEmpty, !reflowTextSelection.isEmpty { reflowTextSelection = [] }
        if translationSelectedIDs != ids { translationSelectedIDs = ids }
    }

    func validatedText(for piece: PDFReflowTextSelection) -> String? {
        guard let page = loadedPages[piece.sentence.pageIndex],
            page.originalSentences.contains(piece.sentence) || page.paragraph.sentences.contains(piece.sentence)
        else { return nil }
        let displayed: String?
        switch piece.language {
        case "en": displayed = piece.sentence.text
        case "zh": displayed = page.paragraph.translations[piece.sentence.id]
        default: return nil
        }
        guard let text = displayed as NSString?, piece.range.location >= 0, piece.range.location <= text.length,
            piece.range.length > 0, piece.range.length <= text.length - piece.range.location,
            text.substring(with: piece.range) == piece.text
        else { return nil }
        return displayed
    }

    func matches(_ model: ReaderModel) -> Bool {
        isOpen && model.mode == "original" && model.selectedPaperID == paperID && model.visiblePage == pageIndex
    }

    private func translate(_ items: [PDFSourceSentence], model: ReaderModel, selection: Bool) {
        guard let paper = model.paper, !items.isEmpty else { return }
        let settings = model.modelSettings
        error = nil
        let token = UUID()
        requestID = token
        isTranslating = true
        let update: @MainActor @Sendable ([String: String]) -> Void = { [weak self] values in
            guard let self, self.requestID == token else { return }
            if selection {
                self.selectionTranslation = values[items[0].id]
            } else {
                self.receiveDocumentTranslations(values, paperID: paper.id, page: items[0].pageIndex)
            }
        }
        translationTask = Task {
            defer { if requestID == token { isTranslating = false } }
            do {
                let result = try await model.pdfTranslations.translate(
                    documentHash: paper.digest, sentences: items, settings: settings, client: model.client,
                    key: { try await model.modelKey(for: settings) },
                    onUpdate: { values in await update(values) })
                update(result)
            } catch {
                if requestID == token, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
