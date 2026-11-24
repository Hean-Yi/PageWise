import Foundation
import Observation
import PaperReaderKit

/// Owns request lifetimes independently of the inline view's appearance.
@MainActor @Observable
public final class OnlinePaperSearch {
    public var query = ""
    public private(set) var scope: PaperSearchScope = .all
    private var displayedResult: (query: String, candidates: [PaperCandidate], notice: String?)?
    var resultQuery: String? { displayedResult?.query }
    public var sourceNotice: String? { displayedResult?.notice }
    public var results: [PaperCandidate] { displayedResult?.candidates ?? [] }
    public private(set) var isExpanded = false
    private var activeQuery: String?
    public var isSearching: Bool { activeQuery != nil }
    var canSearch: Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && term != activeQuery && importingID == nil
    }
    public private(set) var searched = false
    private var failure: (reason: String, webSearchURL: URL?)?
    public var error: String? { failure?.reason }
    var webSearchURL: URL? { failure?.webSearchURL }
    public private(set) var contextNotice: String?
    public private(set) var importingID: String?
    private var importStage = "下载 TeX 与原版 PDF"
    public var importProgress: String {
        if importStage == "本地处理", let progress = reader.importProgress { return progress }
        return importStage
    }
    private var sessionImports: [String: (paperID: UUID, hadDownload: Bool)] = [:]
    public var imported: [String: UUID] { sessionImports.mapValues(\.paperID) }
    public private(set) var importErrors: [String: String] = [:]
    public private(set) var targetShelfID: UUID?
    public private(set) var closing = false
    private let reader: ReaderModel
    private let discovery: any PaperDiscovery
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var importTask: Task<Void, Never>?
    private var pinnedEdition: (candidate: PaperCandidate, awaitingFile: Bool)?
    var selectedPublicationID: String? { pinnedEdition?.candidate.id }

    public init(reader: ReaderModel, discovery: any PaperDiscovery = FederatedPaperDiscovery.shared) {
        self.reader = reader
        self.discovery = discovery
    }

    public func open(shelfID: UUID?) {
        guard !closing else { return }
        if targetShelfID != shelfID {
            guard importTask == nil else {
                contextNotice = "正在导入到原书架；完成后再次点击目标书架的加号。"
                return
            }
            cancelSearch()
            targetShelfID = shelfID
            displayedResult = nil
            searched = false
            failure = nil
            sessionImports = [:]
            importErrors = [:]
        }
        // A paper may have been moved through the cover menu since the last query.
        sessionImports = sessionImports.filter { _, entry in
            reader.state.papers.contains(where: { $0.id == entry.paperID })
                && reader.state.shelfID(for: entry.paperID) == shelfID
        }
        contextNotice = nil
        isExpanded = true
    }

    public func close() {
        cancelSearch()
        if importTask != nil {
            closing = true
            importTask?.cancel()
        } else {
            isExpanded = false
        }
    }

    public func cancelSearch() {
        generation = UUID()
        pinnedEdition = nil
        searchTask?.cancel()
        searchTask = nil
        activeQuery = nil
    }

    func selectScope(_ scope: PaperSearchScope) {
        guard self.scope != scope, importTask == nil else { return }
        self.scope = scope
        let hadSearch = isSearching || searched || error != nil
        cancelSearch()
        displayedResult = nil
        failure = nil
        searched = false
        if hadSearch { search() }
    }

    public func search() {
        guard canSearch else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        let token = generation
        activeQuery = term
        displayedResult = nil
        failure = nil
        searched = false
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.discovery.discover(term, scope: self.scope, limit: 8) {
                    [weak self] update in
                    await self?.apply(update, generation: token)
                }
                guard token == self.generation, !Task.isCancelled else { return }
                self.apply(result, generation: token)
                self.searched = true
            } catch is CancellationError {
                // A cancelled search has no result count to show.
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.failure = (error.localizedDescription, Self.webSearchURL(for: term, error: error))
            }
            guard token == self.generation else { return }
            self.activeQuery = nil
            self.searchTask = nil
        }
    }

    private func apply(_ result: OnlineDiscoveryResult, generation: UUID) {
        guard generation == self.generation, !Task.isCancelled, let activeQuery else { return }
        var seen: Set<String> = []
        var candidates = result.candidates.compactMap(\.verified).filter { seen.insert($0.id).inserted }
        // A later index can move the chosen edition into another card or beyond the result limit.
        // Keep the chosen edition visible during acquisition and after it completes.
        if let selected = pinnedEdition?.candidate,
            !candidates.contains(where: { card in
                card.id == selected.id || card.alternateVersions.contains(where: { $0.id == selected.id })
            })
        {
            candidates.append(selected)
        }
        displayedResult = (activeQuery, candidates, result.notice)
    }

    private static func webSearchURL(for term: String, error: any Error) -> URL? {
        guard (error as? ArxivQueryError)?.offersWebSearch == true else { return nil }
        var search = URLComponents()
        search.scheme = "https"
        search.host = "arxiv.org"
        search.path = "/search/"
        search.queryItems = [.init(name: "query", value: term), .init(name: "searchtype", value: "title")]
        // HTML form decoding treats a literal plus in a query string as a space.
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return search.url
    }

    public func cancelImport() { importTask?.cancel() }

    func importedPaperID(for candidate: PaperCandidate) -> UUID? {
        if let entry = sessionImports[candidate.id], entry.hadDownload || !candidate.canDownload,
            reader.state.papers.contains(where: { $0.id == entry.paperID }),
            reader.state.shelfID(for: entry.paperID) == targetShelfID
        {
            return entry.paperID
        }
        return reader.importedPaperID(for: candidate, includeUserLinked: !candidate.canDownload) {
            reader.state.shelfID(for: $0.id) == targetShelfID
        }
    }

    func openImported(_ candidate: PaperCandidate) {
        if let id = importedPaperID(for: candidate) { reader.select(id) }
    }

    func choosePDF(for candidate: PaperCandidate) -> Bool {
        guard isExpanded, !closing, importTask == nil, var candidate = registeredCandidate(candidate.id),
            !candidate.canDownload || importErrors[candidate.id] != nil, importedPaperID(for: candidate) == nil
        else { return false }
        candidate.alternateVersions = []
        pinnedEdition = (candidate, true)
        return true
    }

    func importSelectedPDF(_ url: URL) {
        guard isExpanded, let selection = pinnedEdition, selection.awaitingFile else { return }
        pinnedEdition?.awaitingFile = false
        startImport(selection.candidate, selectedPDF: url)
    }

    func cancelFileSelection() {
        if pinnedEdition?.awaitingFile == true { pinnedEdition = nil }
    }

    func fileSelectionFailed(_ error: Error) {
        guard isExpanded, !closing, let selection = pinnedEdition, selection.awaitingFile else { return }
        pinnedEdition?.awaitingFile = false
        importErrors[selection.candidate.id] = error.localizedDescription
    }

    private func registeredCandidate(_ id: String) -> PaperCandidate? {
        results.lazy.flatMap { [$0] + $0.alternateVersions }.first { $0.id == id }
    }

    public func confirmImport(_ candidate: PaperCandidate) {
        guard var candidate = registeredCandidate(candidate.id), candidate.canAttemptDownload else {
            return
        }
        candidate.alternateVersions = []
        startImport(candidate, selectedPDF: nil)
    }

    private func startImport(_ candidate: PaperCandidate, selectedPDF: URL?) {
        guard importTask == nil, !closing, selectedPDF != nil || importedPaperID(for: candidate) == nil else { return }
        let shelfID = targetShelfID
        guard shelfID == nil || reader.state.shelves.contains(where: { $0.id == shelfID }) else {
            importErrors[candidate.id] = "目标书架已删除，请关闭查找后从其他书架重试。"
            return
        }
        if selectedPDF != nil {
            importStage = "本地处理"
        } else {
            pinnedEdition = (candidate, false)
            if candidate.canDownload {
                importStage = candidate.source == .arxiv ? "下载 TeX 与原版 PDF" : "下载原版 PDF"
            } else {
                importStage = "查找并下载开放全文"
            }
        }
        importingID = candidate.id
        importErrors[candidate.id] = nil
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importTask = nil
                self.importingID = nil
                self.contextNotice = nil
                if self.closing {
                    self.isExpanded = false
                    self.closing = false
                }
            }
            do {
                try Task.checkCancellation()
                let id: UUID
                if let selectedPDF {
                    id = try await self.reader.importPublisherPDF(
                        selectedPDF, for: candidate, shelfID: shelfID, moveDuplicateToShelf: true)
                } else {
                    let download = try await self.discovery.downloadPublication(candidate)
                    let url = download.pdfURL
                    defer { try? FileManager.default.removeItem(at: url) }
                    try Task.checkCancellation()
                    self.importStage = "本地处理"
                    let ids = await self.reader.importURLs(
                        [url], selectAfterImport: false, metadata: download.candidate, shelfID: shelfID,
                        moveDuplicateToShelf: true, onlineDownload: download)
                    guard let importedID = ids.first else {
                        try Task.checkCancellation()
                        throw ReaderError.message(self.reader.message ?? "论文导入未完成，请重试或手动导入 PDF。")
                    }
                    id = importedID
                }
                // Later indexes may supply a verified download for a formerly metadata-only edition.
                self.sessionImports[candidate.id] = (id, selectedPDF == nil || candidate.canDownload)
            } catch is CancellationError {
                self.importErrors[candidate.id] = "已停止，可重新导入。"
            } catch {
                self.importErrors[candidate.id] = error.localizedDescription
            }
        }
    }
}
