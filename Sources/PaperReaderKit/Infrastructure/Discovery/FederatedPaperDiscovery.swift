import Foundation

public struct FederatedSearchError: LocalizedError, Sendable {
    public let errorDescription: String?
    public let canRefineQuery: Bool
}

/// Keeps the existing arXiv version resolver behind its own source, alongside independent bibliographic indexes.
public struct FederatedPaperDiscovery: PaperDiscovery {
    public static let shared = FederatedPaperDiscovery()
    private let arxiv: any PaperDiscovery
    private let indexes: ScholarlyIndexes
    private let openAccess: IndexedOpenCopies
    private let sourceTimeout: Duration

    public init() {
        self.init(arxiv: ArxivClient(), transport: NetworkTransport())
    }

    init(arxiv: any PaperDiscovery, transport: any HTTPTransport, sourceTimeout: Duration = .seconds(12)) {
        self.arxiv = arxiv
        self.indexes = ScholarlyIndexes(transport: transport)
        self.openAccess = IndexedOpenCopies(transport: transport)
        self.sourceTimeout = sourceTimeout
    }

    public func search(_ query: String) async throws -> [PaperCandidate] {
        try await search(query, limit: 8)
    }

    public func search(_ query: String, limit: Int) async throws -> [PaperCandidate] {
        try await discover(query, scope: .all, limit: limit).candidates
    }

    private enum Response: Sendable {
        case hits(PaperSearchSource, [PaperCandidate])
        case unavailable(PaperSearchSource, String, canRefine: Bool)
    }

    public func discover(
        _ query: String, scope: PaperSearchScope, limit: Int, onUpdate: @Sendable (OnlineDiscoveryResult) async -> Void
    ) async throws -> OnlineDiscoveryResult {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(40, limit)
        guard query.utf8.count <= 4_096 else { throw ReaderError.message("检索词过长，请缩短后重试。") }
        guard !query.isEmpty, limit > 0 else { return .init(candidates: []) }

        if scope == .arxiv {
            return .init(candidates: try await arxiv.search(query, limit: limit))
        }
        return try await withThrowingTaskGroup(of: Response.self) { group in
            for source in scope.sources {
                group.addTask {
                    do {
                        let records = try await lookup(query, source: source, limit: limit, bounded: scope == .all)
                        return .hits(source, records)
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        return .unavailable(
                            source, error.localizedDescription,
                            canRefine: (error as? ArxivQueryError)?.canRefineQuery == true)
                    }
                }
            }

            var hits: [PaperSearchSource: [PaperCandidate]] = [:]
            var failures: [PaperSearchSource: String] = [:]
            var canRefine = false
            var result = OnlineDiscoveryResult(candidates: [])
            for try await response in group {
                try Task.checkCancellation()
                switch response {
                case .hits(let source, let records): hits[source] = records
                case .unavailable(let source, let message, let refine):
                    failures[source] = message
                    canRefine = canRefine || refine
                }
                let sources = scope.sources
                let unavailable = sources.filter { failures[$0] != nil }.map(\.label)
                let notice = unavailable.isEmpty ? nil : unavailable.joined(separator: "、") + " 暂未完成检索"
                let lists = sources.compactMap { hits[$0] }
                result = .init(
                    candidates: PaperDiscoveryRanking.merge(lists, query: query, limit: limit), notice: notice)
                if !hits.isEmpty { await onUpdate(result) }
            }
            try Task.checkCancellation()
            if hits.isEmpty {
                let details = scope.sources.compactMap { source in failures[source].map { "\(source.label) · \($0)" } }
                throw FederatedSearchError(errorDescription: details.joined(separator: "\n"), canRefineQuery: canRefine)
            }
            return result
        }
    }

    private func lookup(_ query: String, source: PaperSearchSource, limit: Int, bounded: Bool) async throws
        -> [PaperCandidate]
    {
        let search: @Sendable () async throws -> [PaperCandidate] = {
            switch source {
            case .arxiv: return try await arxiv.search(query, limit: limit)
            case .crossref: return try await indexes.crossref(query, limit: limit)
            case .dblp: return try await indexes.dblp(query, limit: limit)
            case .semanticScholar: throw ReaderError.message("相关论文推荐需要一篇起始论文。")
            }
        }
        guard bounded else { return try await search() }
        return try await withThrowingTaskGroup(of: [PaperCandidate].self) { race in
            race.addTask(operation: search)
            race.addTask {
                try await Task.sleep(for: sourceTimeout)
                throw ReaderError.message("本次检索超时。")
            }
            defer { race.cancelAll() }
            guard let first = try await race.next() else { throw CancellationError() }
            return first
        }
    }

    public func related(title: String, sourceID: String?, limit: Int) async throws -> [PaperCandidate] {
        let limit = min(40, limit)
        guard limit > 0 else { return [] }
        do {
            let records: [PaperCandidate]
            if let seed = sourceID.flatMap(ScholarlyIndexes.recommendationID) {
                records = try await indexes.related(to: seed, limit: limit)
            } else {
                records = try await indexes.relatedByTitle(title, limit: limit)
            }
            return PaperDiscoveryRanking.merge([records], query: nil, limit: limit)
        } catch let error as ScholarlyIndexes.Failure {
            let refine: Bool
            switch error {
            case .invalidQuery, .ambiguousTitle, .unknownSeed: refine = true
            default: refine = false
            }
            throw FederatedSearchError(errorDescription: error.localizedDescription, canRefineQuery: refine)
        }
    }

    public func download(_ candidate: PaperCandidate) async throws -> URL {
        try await downloadPublication(candidate).pdfURL
    }

    public func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication {
        if candidate.source == .arxiv { return try await arxiv.downloadPublication(candidate) }
        return try await openAccess.download(candidate)
    }

    public func structuredContent(_ candidate: PaperCandidate) async throws -> [TextBlock]? {
        guard candidate.source == .arxiv else { return nil }
        return try await arxiv.structuredContent(candidate)
    }
}
