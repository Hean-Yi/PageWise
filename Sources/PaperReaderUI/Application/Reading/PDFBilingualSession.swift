import CryptoKit
import Foundation
import Observation
import PaperReaderKit

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

    private var paragraphLayout = false
    private var paperID: UUID?
    private(set) var pageIndex = -1
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestID = UUID()

    func open(_ model: ReaderModel, translatingDocument: Bool = false) {
        guard model.mode == "original", model.paper != nil else { return }
        isOpen = true
        loadPage(model)
        if translatingDocument { setParagraphLayout(true, model: model) }
    }

    func setParagraphLayout(_ enabled: Bool, model: ReaderModel) {
        guard matches(model), let paper = model.paper else { return }
        paragraphLayout = enabled
        if enabled { model.pdfDocumentTranslation.start(model, paper: paper, page: pageIndex) }
    }

    func resumeDocumentTranslation(_ model: ReaderModel) {
        guard matches(model), let paper = model.paper else { return }
        model.pdfDocumentTranslation.start(model, paper: paper, page: pageIndex, resuming: true)
    }

    func receiveDocumentTranslations(_ values: [String: String], paperID: UUID, page: Int) {
        guard isOpen, self.paperID == paperID, pageIndex == page else { return }
        translations.merge(values) { _, new in new }
    }

    func settingsChanged(_ model: ReaderModel, previous: ModelSettings, credentialRemoved: Bool) {
        model.pdfDocumentTranslation.settingsChanged(
            model, previousSettings: previous, resumeVisible: paragraphLayout && !credentialRemoved)
        guard matches(model) else { return }
        pageIndex = -1
        loadPage(model)
    }

    func close() {
        isOpen = false
        paragraphLayout = false
        loadTask?.cancel()
        pause()
        isLoading = false
        generation = UUID()
        hoveredID = nil
        illustrations = []
        sourceIllustration = nil
        // Invalidate the page so reopening also rereads the persisted translations.
        pageIndex = -1
    }

    func loadPage(_ model: ReaderModel) {
        guard isOpen, model.mode == "original", let paper = model.paper else { return }
        let index = model.visiblePage
        guard paper.id != paperID || index != pageIndex else { return }
        loadTask?.cancel()
        pause()
        let token = UUID()
        generation = token
        if paper.id != paperID || pageIndex != -1 { focusedID = nil }
        paperID = paper.id
        pageIndex = index
        sourceScrollID = nil
        pdfScrollID = nil
        translationSelectedIDs = []
        pdfSelectedIDs = []
        hoveredID = nil
        sentences = []
        paragraphSentences = []
        illustrations = []
        sourceIllustration = nil
        translations = [:]
        selectionSource = nil
        selectionTranslation = nil
        notice = nil
        error = nil
        isLoading = true
        let url = model.root.appendingPathComponent(paper.originalPath)
        let settings = model.pdfTranslationSettings
        let store = model.pdfTranslations
        loadTask = Task {
            defer { if generation == token { isLoading = false } }
            do {
                let extraction = Task.detached(priority: .userInitiated) {
                    try PDFSentenceExtractor.extractPage(url: url, pageIndex: index, includingIllustrations: true)
                }
                let page = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: {
                    extraction.cancel()
                }
                guard generation == token, !Task.isCancelled else { return }
                sentences = page.sentences
                paragraphSentences = page.paragraphSentences
                illustrations = page.illustrations
                notice = page.notice
                if let focusedID, !sentences.contains(where: { $0.id == focusedID }) { self.focusedID = nil }
                let cached = try await store.cached(
                    documentHash: paper.digest, sentences: page.sentences,
                    settings: settings.model.isEmpty ? nil : settings)
                if generation == token, !Task.isCancelled {
                    // Whole-document work can publish this page while the actor is reading its cache.
                    translations.merge(cached) { published, _ in published }
                }
            } catch {
                if generation == token, !Task.isCancelled { self.error = error.localizedDescription }
            }
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
                self.translations.merge(values) { _, new in new }
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
