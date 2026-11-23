import Foundation
import Observation
import PaperReaderKit

@MainActor @Observable
public final class ReaderModel {
    public var state = LibraryState()
    public var selectedPaperID: UUID?
    public var selectedSection = "library"
    public var mode = "reflow"
    public var message: String?
    public var status = "仅保存在此设备"
    public var isImporting = false
    public var importProgress: String?
    public var selectionHTMLRange: [Int]?
    public var requestedReadingNote: UUID?
    public var readingNoteNavigationToken = UUID()
    public var lastDeletedNoteID: UUID?
    public var noteRevision = 0
    public var savedNoteRevision = 0
    public var noteSaveFailed = false
    @ObservationIgnored var noteSaveTask: Task<Void, Never>?
    public var htmlSelection: [HTMLTextSelection] = []
    public var usesHTMLReading: Bool { mode == "translated" && paper?.htmlReading != nil }
    public var translationDraft: TranslationDraft?
    public var translationPauseReason: String?
    public var retainedReadingID: UUID?
    public var reflowStages: [UUID: String] = [:]
    public var reflowStartedAt: [UUID: Date] = [:]
    public var reflowBodyCount = 0
    @ObservationIgnored var reflowPresenting: Set<UUID> = []
    public var assistantDraft: ChatTurn?
    public var busyAI = false
    public var translating: Set<UUID> = []
    public private(set) var pendingArtifactIDs: Set<UUID> = []
    var pendingImportIDs: Set<UUID> = []
    public private(set) var modelSettings = ModelSettings()
    public var selectionText = ""
    public var selectionRects: [[Double]] = []
    public var selectionPage = 0
    var pdfSelectionSpansPages = false
    var pdfSelectionRanges: [NSRange] = []
    let pdfBilingual = PDFBilingualSession()
    let pdfDocumentTranslation = PDFDocumentTranslationController()
    let pdfTranslations: PDFSentenceTranslationStore
    let translationValidation: PDFTranslationValidationConfiguration?
    public var visiblePage = 0 {
        didSet {
            if oldValue != visiblePage, mode == "original", let id = selectedPaperID {
                pdfDocumentTranslation.prioritize(id, page: visiblePage)
            }
        }
    }
    public var jumpPage: Int? {
        didSet { jumpOutlineItem = nil }
    }
    var jumpOutlineItem: PaperNavigationItem?
    public var navigationItems: [PaperNavigationItem] = []
    var loadedNavigationDocumentID: String?
    public var navigationLoading = false
    public var vaultName = "未选择目录"
    public var loaded = false
    public var loadFailure: String?
    public let root: URL
    let store: LibraryStore
    let importer: PDFImporter
    let client: ModelClient
    let configurationStore: ModelConfigurationStore
    let vault: VaultService
    let outlineService = PDFOutlineService()
    let pageTextLocator: any FixedPageTextLocating
    @ObservationIgnored private var saveQueue: Task<Bool, Never>?
    @ObservationIgnored var highlightSaveTask: Task<Bool, Never>?
    @ObservationIgnored var workspaceSaveTask: Task<Void, Never>?
    @ObservationIgnored var workspaceRevision = 0
    @ObservationIgnored var savedWorkspaceRevision = 0
    @ObservationIgnored var navigationRequestID: UUID?
    @ObservationIgnored var searchNavigationRequestID: UUID?
    @ObservationIgnored var searchNavigationTask: Task<Void, Never>?
    @ObservationIgnored var translationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var readingStart: Date?
    @ObservationIgnored var readingPaper: UUID?
    @ObservationIgnored var lastInteraction = Date()
    @ObservationIgnored var isActive = true

    public init(
        root: URL? = nil, client: ModelClient = ModelClient(),
        credentials: any ModelCredentialStore = DeviceModelCredentials(),
        pageTextLocator: any FixedPageTextLocating = PDFPageTextLocator(),
        translationValidation: PDFTranslationValidationConfiguration? = nil
    ) throws {
        self.client = client
        self.pageTextLocator = pageTextLocator
        let location =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperReader", isDirectory: true)
        self.root = location
        pdfTranslations = PDFSentenceTranslationStore(root: location)
        self.translationValidation = translationValidation ?? PDFTranslationValidationConfiguration.load(root: location)
        store = try LibraryStore(directory: location)
        importer = PDFImporter(root: location)
        vault = VaultService(root: location)
        configurationStore = ModelConfigurationStore(directory: location, credentials: credentials)
        let saved = try configurationStore.load()
        modelSettings = saved.model.isEmpty ? self.translationValidation?.settings ?? saved : saved
    }

    var currentEdition: Paper? { state.papers.first(where: { $0.id == selectedPaperID }) }
    public var paper: Paper? {
        guard let current = currentEdition else { return nil }
        if let version = current.retainedReadings?.first(where: { $0.id == retainedReadingID }) {
            return version.projecting(current)
        }
        return current
    }
    public var showingReflowLoading: Bool {
        mode == "translated" && retainedReadingID == nil
            && (paper?.reflowJob?.supportsContinuation == true
                || selectedPaperID.map { translating.contains($0) } == true)
            && paper?.reflowJob?.hasPresentedContent != true
    }
    var showsPDFCanvas: Bool {
        paper != nil && !usesHTMLReading && !showingReflowLoading
    }
    public var activePages: [PageArtifact] {
        guard let paper else { return [] }
        let pages = mode == "translated" ? paper.readingPages : paper.previewPages
        return pages.filter { !pendingArtifactIDs.contains($0.id) }
    }
    public var pageURLs: [URL] {
        guard let paper else { return [] }
        if mode == "original" || !paper.canReflow { return [root.appendingPathComponent(paper.originalPath)] }
        return activePages.map { root.appendingPathComponent($0.relativePath) }
    }
    public var pageKeys: [String] {
        guard let paper else { return [] }
        if mode == "original" || !paper.canReflow { return (0..<paper.pageCount).map { "original-\($0)" } }
        return activePages.map { $0.id.uuidString }
    }
    public var currentHighlights: [Highlight] { state.highlights.filter { $0.paperID == selectedPaperID } }
    public var currentChats: [ChatTurn] { state.chats.filter { $0.paperID == selectedPaperID } }

    public func load() async {
        guard !loaded else { return }
        do {
            state = try await store.load()
            do { try ReadingArtifactCleanup.removeUncommittedFiles(in: root, papers: state.papers) } catch {
                status = "部分临时文件暂未清理，将在下次打开时重试。"
            }
            if let folder = try? await vault.directory() { vaultName = folder.lastPathComponent }
            loaded = true
        } catch {
            loadFailure = error.localizedDescription
            message = error.localizedDescription
        }
    }

    public func select(_ id: UUID?) {
        if let id, pendingImportIDs.contains(id) { return }
        if let id, !state.papers.contains(where: { $0.id == id }) { return }
        Task { await flushReadingNotes() }
        requestedReadingNote = nil
        let changedPaper = selectedPaperID != id
        if changedPaper {
            pdfBilingual.close()
            translationPauseReason = nil
        }
        invalidateSearchNavigation()
        endReading()
        selectedPaperID = id
        retainedReadingID = nil
        reflowBodyCount = 0
        if let current = state.papers.first(where: { $0.id == id }) {
            let position = workspace(for: current.id).position
            if let key = position?.pageKey, !current.readingPages.contains(where: { $0.id.uuidString == key }) {
                retainedReadingID =
                    current.retainedReadings?.first(where: { $0.readingPages.contains { $0.id.uuidString == key } })?.id
            }
        }
        selectionText = ""
        selectionRects = []
        visiblePage = 0
        jumpPage = nil
        if changedPaper {
            loadedNavigationDocumentID = nil
            navigationRequestID = nil
            navigationLoading = false
            navigationItems = []
        }
        selectedSection = "library"
        restoreWorkspace()
        beginReading()
    }

    @discardableResult func save(
        cancellable: Bool = false, adding importedPaper: Paper? = nil,
        shelfChange: ShelfChange? = nil, importShelfID: UUID? = nil,
        orderChange: LibraryOrderChange? = nil, publishingReflow publication: Paper? = nil,
        presentingReflow: (paperID: UUID, jobID: UUID)? = nil
    ) async -> Bool {
        guard loaded else { return false }
        let previous = saveQueue
        let store = store
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            do {
                if cancellable { try Task.checkCancellation() }
                // Take the latest state after preceding writes. Uncommitted imports never enter
                // public state or unrelated queued snapshots, and are published only after commit.
                var snapshot = self.state
                if let importedPaper {
                    snapshot.papers.insert(importedPaper, at: 0)
                    if let importShelfID {
                        try snapshot.apply(.move(paperID: importedPaper.id, shelfID: importShelfID))
                    }
                }
                if let shelfChange { try snapshot.apply(shelfChange) }
                if let orderChange { try snapshot.apply(orderChange) }
                if let publication {
                    guard let index = snapshot.papers.firstIndex(where: { $0.id == publication.id }) else {
                        throw ReaderError.message("论文已不在书库中，未发布页面。")
                    }
                    Self.applyReflow(publication, to: &snapshot.papers[index])
                }
                if let presentingReflow {
                    guard let index = snapshot.papers.firstIndex(where: { $0.id == presentingReflow.paperID }),
                        snapshot.papers[index].reflowJob?.id == presentingReflow.jobID
                    else { throw CancellationError() }
                    snapshot.papers[index].reflowJob?.hasPresentedContent = true
                }
                try await store.save(snapshot, respectingCancellation: cancellable)
                if let importedPaper { self.state.papers.insert(importedPaper, at: 0) }
                if let publication, let index = self.state.papers.firstIndex(where: { $0.id == publication.id }) {
                    let wasLocal = !self.state.papers[index].usesSourceReflow
                    Self.applyReflow(publication, to: &self.state.papers[index])
                    if wasLocal, self.state.papers[index].usesSourceReflow {
                        self.pdfDocumentTranslation.discard(publication.id)
                        if self.selectedPaperID == publication.id { self.pdfBilingual.close() }
                    }
                }
                if let presentingReflow,
                    let index = self.state.papers.firstIndex(where: { $0.id == presentingReflow.paperID }),
                    self.state.papers[index].reflowJob?.id == presentingReflow.jobID
                {
                    self.state.papers[index].reflowJob?.hasPresentedContent = true
                }
                self.state.shelves = snapshot.shelves
                self.state.paperShelfIDs = snapshot.paperShelfIDs
                self.state.manualPaperIDs = snapshot.manualPaperIDs
                self.state.preferredSort = snapshot.preferredSort
                return true
            } catch is CancellationError {
                return false
            } catch {
                self.message = "本地保存失败：\(error.localizedDescription)"
                return false
            }
        }
        saveQueue = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            if cancellable { task.cancel() }
        }
    }

    private static func applyReflow(_ publication: Paper, to paper: inout Paper) {
        let alreadyPresented =
            paper.reflowJob?.id == publication.reflowJob?.id && paper.reflowJob?.hasPresentedContent == true
        paper.reflowJob = publication.reflowJob
        if paper.onlineSource?.archivePath == nil, let source = publication.onlineSource { paper.onlineSource = source }
        if alreadyPresented { paper.reflowJob?.hasPresentedContent = true }
        paper.retainedReadings = publication.retainedReadings
        paper.canReflow = publication.canReflow
        paper.warnings = publication.warnings
        paper.blocks = publication.blocks
        paper.translations = publication.translations
        paper.translatedPages = publication.translatedPages
        paper.htmlReading = publication.htmlReading
        paper.translatedBlockCount = publication.translatedBlockCount
    }

    public func captureSelection(
        text: String, rects: [[Double]], page: Int, spansPages: Bool = false, ranges: [NSRange] = []
    ) {
        if mode == "original", !text.isEmpty { pdfBilingual.selectFromTranslation([]) }
        pdfSelectionRanges = ranges
        pdfSelectionSpansPages = spansPages
        selectionHTMLRange = nil
        htmlSelection = []
        selectionText = text
        selectionRects = rects
        selectionPage = page
        touch()
    }

    public func highlightSelection() {
        guard let id = selectedPaperID, !selectionText.isEmpty, pageKeys.indices.contains(selectionPage) else { return }
        if usesHTMLReading, !htmlSelection.isEmpty {
            for part in htmlSelection {
                guard let index = pageKeys.firstIndex(of: part.pageKey) else { continue }
                let start = part.highlightStart ?? part.start
                let end = part.highlightEnd ?? part.end
                guard start >= part.start, end <= part.end, end > start else { continue }
                let text = (part.text as NSString).substring(
                    with: NSRange(location: start - part.start, length: end - start))
                var highlight = Highlight(
                    paperID: id, pageKey: part.pageKey, pageIndex: index, text: text, rects: [])
                highlight.textRange = [start, end]
                highlight.htmlTarget = part.target
                state.highlights.append(highlight)
            }
        } else {
            var highlight = Highlight(
                paperID: id, pageKey: pageKeys[selectionPage], pageIndex: selectionPage, text: selectionText,
                rects: selectionRects)
            highlight.textRange = selectionHTMLRange
            state.highlights.append(highlight)
        }
        highlightSaveTask = Task { await save() }
    }

    @discardableResult
    public func saveSettings(_ draft: ModelSettings, key: String?, removeKey: Bool = false) throws -> String? {
        let result = try configurationStore.save(draft, key: key, removeKey: removeKey)
        let changed = modelSettings != result.settings || removeKey || key?.isEmpty == false
        let previous = modelSettings
        modelSettings = result.settings
        if changed {
            pdfBilingual.settingsChanged(self, previous: previous, credentialRemoved: removeKey)
            for task in translationTasks.values { task.cancel() }
        }
        status = result.warning ?? "模型设置已保存，下次模型请求将使用新配置"
        return result.warning
    }

    public func selectVault(_ url: URL) async {
        do {
            try await vault.select(url)
            vaultName = url.lastPathComponent
        } catch { message = error.localizedDescription }
    }

}
