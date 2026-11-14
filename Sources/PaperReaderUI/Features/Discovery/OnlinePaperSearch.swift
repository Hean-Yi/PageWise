import Foundation
import Observation
import PaperReaderKit

/// Owns request lifetimes independently of the inline view's appearance.
@MainActor @Observable
public final class OnlinePaperSearch {
    public var query = ""
    public private(set) var results: [PaperCandidate] = []
    public private(set) var isExpanded = false
    public private(set) var isSearching = false
    public private(set) var searched = false
    public private(set) var error: String?
    public private(set) var contextNotice: String?
    public private(set) var importingID: String?
    private var importStage = "下载 PDF"
    public var importProgress: PDFImportProgress {
        if importStage == "本地处理", let progress = reader.importProgress { return progress }
        return PDFImportProgress(sequence: 0, stage: importStage)
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
            error = nil
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
        isSearching = false
    }

    public func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, importTask == nil else { return }
        cancelSearch()
        let token = generation
        isSearching = true
        error = nil
        results = []
        searched = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await self.discovery.search(term)
                guard token == self.generation, !Task.isCancelled else { return }
                var seen: Set<String> = []
                self.results = candidates.filter {
                    ArxivClient.verified($0) != nil && seen.insert($0.id).inserted
                }
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard token == self.generation else { return }
            self.isSearching = false
            self.searchTask = nil
        }
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
        importStage = "下载 PDF"
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
                let url = try await self.discovery.download(candidate)
                defer { try? FileManager.default.removeItem(at: url) }
                self.importStage = "获取正文与图片"
                let structured: [TextBlock]?
                do { structured = try await self.discovery.structuredContent(candidate) } catch is CancellationError {
                    throw CancellationError()
                } catch { structured = nil }
                try Task.checkCancellation()
                self.importStage = "本地处理"
                let ids = await self.reader.importURLs(
                    [url], selectAfterImport: false, metadata: candidate, shelfID: shelfID, moveDuplicateToShelf: true,
                    structuredBlocks: structured)
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
