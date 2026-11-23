import Foundation
import Observation
import PaperReaderKit

/// Owns request lifetimes independently of the inline view's appearance.
@MainActor @Observable
public final class OnlinePaperSearch {
    public var query = ""
    public private(set) var results: [PaperCandidate] = []
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
    public private(set) var imported: [String: UUID] = [:]
    public private(set) var importErrors: [String: String] = [:]
    public private(set) var targetShelfID: UUID?
    public private(set) var closing = false
    private let reader: ReaderModel
    private let discovery: any PaperDiscovery
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var importTask: Task<Void, Never>?

    public init(reader: ReaderModel, discovery: any PaperDiscovery = ArxivClient()) {
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
            results = []
            searched = false
            failure = nil
            imported = [:]
            importErrors = [:]
        }
        // A paper may have been moved through the cover menu since the last query.
        imported = imported.filter { _, id in
            reader.state.papers.contains(where: { $0.id == id }) && reader.state.shelfID(for: id) == shelfID
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
        searchTask?.cancel()
        searchTask = nil
        activeQuery = nil
    }

    public func search() {
        guard canSearch else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        let token = generation
        activeQuery = term
        failure = nil
        results = []
        searched = false
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await self.discovery.search(term)
                guard token == self.generation, !Task.isCancelled else { return }
                var seen: Set<String> = []
                self.results = candidates.filter {
                    ArxivClient.verified($0) != nil && seen.insert($0.id).inserted
                }
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

    private static func webSearchURL(for term: String, error: any Error) -> URL? {
        guard let failure = error as? ArxivQueryError, case .http(let status, _) = failure,
            status == 429 || (500...599).contains(status)
        else { return nil }
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

    public func confirmImport(_ candidate: PaperCandidate) {
        guard results.contains(where: { $0.id == candidate.id }), ArxivClient.verified(candidate) != nil,
            importTask == nil, !closing
        else { return }
        if let id = imported[candidate.id], reader.state.papers.contains(where: { $0.id == id }),
            reader.state.shelfID(for: id) == targetShelfID
        {
            return
        }
        let shelfID = targetShelfID
        guard shelfID == nil || reader.state.shelves.contains(where: { $0.id == shelfID }) else {
            importErrors[candidate.id] = "目标书架已删除，请关闭查找后从其他书架重试。"
            return
        }
        importStage = "下载 TeX 与原版 PDF"
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
                let download = try await self.discovery.downloadPublication(candidate)
                let url = download.pdfURL
                defer { try? FileManager.default.removeItem(at: url) }
                self.importStage = "获取正文与图片"
                try Task.checkCancellation()
                self.importStage = "本地处理"
                let ids = await self.reader.importURLs(
                    [url], selectAfterImport: false, metadata: download.candidate, shelfID: shelfID,
                    moveDuplicateToShelf: true,
                    onlineDownload: download)
                if let id = ids.first {
                    // A committed import remains successful even if cancellation arrived during commit.
                    self.imported[candidate.id] = id
                } else {
                    try Task.checkCancellation()
                    throw ReaderError.message(self.reader.message ?? "论文导入未完成，请重试或手动导入 PDF。")
                }
            } catch is CancellationError {
                self.importErrors[candidate.id] = "已停止，可重新导入。"
            } catch {
                self.importErrors[candidate.id] = error.localizedDescription
            }
        }
    }
}
