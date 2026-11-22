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
    private(set) var focusedID: String?
    private(set) var hoveredID: String?
    private(set) var sourceFocusRevision = 0
    private(set) var revealRevision = 0
    var followsScroll = true
    private(set) var sourceScrollID: String?
    private(set) var sourceScrollRevision = 0
    private(set) var pdfScrollID: String?
    private(set) var pdfScrollRevision = 0
    private(set) var pdfSelectedIDs: [String] = []
    private(set) var translationSelectedIDs: [String] = []
    private(set) var selectionRequestRevision = 0
    private(set) var selectionSource: String?
    private(set) var selectionTranslation: String?
    var activeID: String? { hoveredID ?? focusedID }
    private var excerptRanges: [NSRange] = []
    var selectionContextID: String? {
        guard selectionSource != nil, !excerptRanges.isEmpty else { return nil }
        let matches = sentences.filter { sentence in
            sentence.characterRanges.contains { span in
                excerptRanges.contains { NSIntersectionRange(span, $0).length > 0 }
            }
        }
        guard matches.count == 1, let id = matches.first?.id, translations[id] != nil else { return nil }
        return id
    }
    func showSelectionContext() {
        guard let id = selectionContextID else { return }
        dismissSelection()
        focus(id)
        sourceFocusRevision &+= 1
    }

    // Page data is local and bounded. Only the explicit paragraph entry authorizes the translation job.
    private var paragraphLayout = false
    private var readingParagraphs = false
    private var paperID: UUID?
    private(set) var pageIndex = -1
    private(set) var paragraphJumpPage = 0
    private(set) var paragraphJumpRevision = 0
    private struct LoadedPage {
        let originalSentences: [PDFSourceSentence]
        let originalNotice: String?
        var paragraph: PDFParagraphPage
    }
    private var loadedPages: [Int: LoadedPage] = [:]
    var paragraphPages: [Int: PDFParagraphPage] { loadedPages.mapValues(\.paragraph) }

    @ObservationIgnored private var loadTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingTranslations: [Int: [String: String]] = [:]
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    func open(_ model: ReaderModel, translatingDocument: Bool = false) {
        guard model.mode == "original", model.paper != nil else { return }
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
        guard matches(model), let paper = model.paper else { return }
        paragraphLayout = enabled
        if enabled {
            prepareParagraphReading(model)
            model.pdfDocumentTranslation.start(model, paper: paper, page: pageIndex)
        } else {
            readingParagraphs = false
            maintainWindow(model)
        }
    }

    func resumeDocumentTranslation(_ model: ReaderModel) {
        guard matches(model), let paper = model.paper else { return }
        model.pdfDocumentTranslation.start(model, paper: paper, page: pageIndex, resuming: true)
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
        paragraphLayout = false
        readingParagraphs = false
        releasePages()
        pause()
        isLoading = false
        hoveredID = nil
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
        requestParagraphJump(index)
        model.jumpPage = nil
    }

    private func requestParagraphJump(_ index: Int) {
        paragraphJumpPage = index
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

    func scrollFromParagraph(_ id: String) {
        guard readingParagraphs, pdfScrollID != id, paragraphSentences.contains(where: { $0.id == id }) else { return }
        sourceIllustration = nil
        pdfScrollID = id
        pdfScrollRevision &+= 1
    }

    func focusParagraphSentence(_ id: String?, model: ReaderModel) {
        if let id {
            guard let entry = loadedPages.values.first(where: { $0.paragraph.sentences.contains { $0.id == id } })
            else { return }
            paragraphDidScroll(to: entry.paragraph.index, model: model)
            guard pageIndex == entry.paragraph.index else { return }
        }
        focus(id)
    }

    func revealParagraphIllustration(_ item: PDFReadingIllustration, model: ReaderModel) {
        paragraphDidScroll(to: item.pageIndex, model: model)
        revealIllustration(item)
    }

    func revealParagraphPage(_ index: Int, model: ReaderModel) {
        paragraphDidScroll(to: index, model: model)
        guard pageIndex == index else { return }
        focus(nil)
        pdfScrollID = nil
    }

    private func activatePage(_ model: ReaderModel, scrolling: Bool) {
        guard isOpen, model.mode == "original", let paper = model.paper else { return }
        let index = model.visiblePage
        guard paper.id != paperID || index != pageIndex else { return }
        if paper.id != paperID { releasePages() }
        pause()
        if paper.id != paperID || pageIndex != -1 { focusedID = nil }
        paperID = paper.id
        pageIndex = index
        sourceScrollID = nil
        pdfScrollID = nil
        translationSelectedIDs = []
        pdfSelectedIDs = []
        hoveredID = nil
        sourceIllustration = nil
        selectionSource = nil
        selectionTranslation = nil
        error = nil
        if readingParagraphs {
            // A recreated canvas opens on the visible page. An existing canvas moves only on a new revision.
            paragraphJumpPage = index
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
        if page != nil, let focusedID, !sentences.contains(where: { $0.id == focusedID }) { self.focusedID = nil }
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
    }

    private func load(_ index: Int, paper: Paper, model: ReaderModel) {
        let url = model.root.appendingPathComponent(paper.originalPath)
        let settings = model.pdfTranslationSettings
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
        translate(sources, model: model, selection: false)
    }

    func translateSelection(_ model: ReaderModel) {
        guard model.mode == "original", !model.pdfSelectionSpansPages, !isTranslating,
            let paper = model.paper, !model.selectionText.isEmpty, !model.selectionRects.isEmpty
        else { return }
        let text = model.selectionText
        let rects = model.selectionRects
        let page = model.selectionPage
        let ranges = model.pdfSelectionRanges
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
        excerptRanges = ranges
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

    func focus(_ id: String?) {
        sourceIllustration = nil
        hoveredID = nil
        focusedID = id
        revealRevision &+= 1
    }

    func focusFromPDF(_ id: String) {
        sourceIllustration = nil
        hoveredID = nil
        focusedID = id
        sourceFocusRevision &+= 1
    }

    func revealIllustration(_ item: PDFReadingIllustration) {
        guard isOpen, item.pageIndex == pageIndex, illustrations.contains(where: { $0.id == item.id }) else { return }
        focus(nil)
        sourceIllustration = item
    }

    func scrollFromTranslation(_ id: String) {
        guard followsScroll, pdfScrollID != id, sentences.contains(where: { $0.id == id }) else { return }
        sourceScrollID = nil
        pdfScrollID = id
        pdfScrollRevision &+= 1
    }

    func scrollFromPDF(_ id: String) {
        guard followsScroll, sourceScrollID != id else { return }
        pdfScrollID = nil
        sourceScrollID = id
        sourceScrollRevision &+= 1
    }

    func selectFromTranslation(_ ids: [String]) {
        if translationSelectedIDs != ids { translationSelectedIDs = ids }
    }

    func selectFromPDF(_ ids: [String]) {
        if pdfSelectedIDs != ids { pdfSelectedIDs = ids }
    }

    func hover(_ id: String?) {
        if hoveredID != id { hoveredID = id }
    }

    func matches(_ model: ReaderModel) -> Bool {
        isOpen && model.mode == "original" && model.selectedPaperID == paperID && model.visiblePage == pageIndex
    }

    private func translate(_ items: [PDFSourceSentence], model: ReaderModel, selection: Bool) {
        guard let paper = model.paper, !items.isEmpty else { return }
        let settings = model.pdfTranslationSettings
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
                    key: {
                        if let key = model.pdfValidation?.key { return key }
                        return try await model.modelKey(for: settings)
                    },
                    onUpdate: { values in await update(values) })
                update(result)
            } catch {
                if requestID == token, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
