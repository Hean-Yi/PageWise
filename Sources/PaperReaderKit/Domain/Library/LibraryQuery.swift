import Foundation

public enum LibraryCollection: String, CaseIterable, Identifiable, Sendable {
    case all, reading, finished, favorites
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "全部论文"
        case .reading: "正在阅读"
        case .finished: "已读"
        case .favorites: "收藏"
        }
    }
    public var icon: String {
        switch self {
        case .all: "books.vertical"
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .favorites: "star"
        }
    }
    public func includes(_ workspace: PaperWorkspace, for paper: Paper) -> Bool {
        switch self {
        case .all: true
        case .reading: ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus == .reading
        case .finished: ReadingProgress.resolve(paper: paper, workspace: workspace).readingStatus == .finished
        case .favorites: workspace.isFavorite
        }
    }
}

public enum LibrarySort: String, CaseIterable, Identifiable, Codable, Sendable {
    case recent, added, title, manual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recent: "最近打开"
        case .added: "添加时间"
        case .title: "标题"
        case .manual: "自定义顺序"
        }
    }
}

public enum LibraryQuery {
    /// Keep meaningful punctuation (e.g. C vs. C++) when comparing titles across the entire library.
    public static func paper(named title: String, in state: LibraryState) -> Paper? {
        func titleKey(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let key = titleKey(title)
        guard !key.isEmpty else { return nil }
        return state.papers.first { titleKey($0.title) == key }
    }

    public static func lastOpenedPaper(in state: LibraryState) -> Paper? {
        state.papers.lazy.compactMap { paper -> (paper: Paper, opened: Date)? in
            state.workspace[paper.id.uuidString]?.lastOpenedAt.map { (paper, $0) }
        }.max { left, right in
            if left.opened != right.opened { return left.opened < right.opened }
            if left.paper.addedAt != right.paper.addedAt { return left.paper.addedAt < right.paper.addedAt }
            return left.paper.id.uuidString > right.paper.id.uuidString
        }?.paper
    }

    public static func searchCandidates(in state: LibraryState, query: String) -> [Paper] {
        let search = TitleSearch(query)
        guard !search.raw.isEmpty else { return [] }
        return state.papers.filter(search.matches).sorted {
            let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    private struct TitleSearch {
        let raw: [Substring]
        let display: [Substring]

        init(_ query: String) {
            raw = query.split(whereSeparator: \.isWhitespace)
            display = PaperTitle.display(query).split(whereSeparator: \.isWhitespace)
        }

        func matches(_ paper: Paper) -> Bool {
            if raw.allSatisfy({ paper.title.localizedStandardContains($0) }) { return true }
            let title = paper.displayTitle
            guard title != paper.title || raw != display else { return false }
            return display.allSatisfy { title.localizedStandardContains($0) }
        }
    }

    public static func papers(
        in state: LibraryState, collection: LibraryCollection = .all, query: String = "", sort: LibrarySort = .recent
    ) -> [Paper] {
        let search = TitleSearch(query)
        let visible = state.papers.filter { paper in
            (collection == .all
                || collection.includes(state.workspace[paper.id.uuidString] ?? PaperWorkspace(), for: paper))
                && search.matches(paper)
        }
        return sorted(visible, in: state, sort: sort, unfinishedFirst: collection == .all)
    }

    /// A nil shelf contains unfiled papers. Search and status collections still span the library.
    public static func papers(onShelf shelfID: UUID?, in state: LibraryState, sort: LibrarySort) -> [Paper] {
        let members = state.papers.filter { state.shelfID(for: $0.id) == shelfID }
        return sorted(members, in: state, sort: sort, unfinishedFirst: true)
    }

    private static func sorted(_ papers: [Paper], in state: LibraryState, sort: LibrarySort, unfinishedFirst: Bool)
        -> [Paper]
    {
        let finishedIDs: Set<UUID> =
            unfinishedFirst
            ? Set(
                papers.lazy.filter {
                    LibraryCollection.finished.includes(state.workspace[$0.id.uuidString] ?? PaperWorkspace(), for: $0)
                }.map(\.id)) : []
        let ranks =
            sort == .manual
            ? Dictionary(uniqueKeysWithValues: state.manualPaperIDs.enumerated().map { ($1, $0) }) : [:]
        return papers.sorted { lhs, rhs in
            let leftFinished = finishedIDs.contains(lhs.id)
            let rightFinished = finishedIDs.contains(rhs.id)
            if leftFinished != rightFinished { return !leftFinished }
            switch sort {
            case .recent:
                let a = state.workspace[lhs.id.uuidString]?.lastOpenedAt ?? .distantPast
                let b = state.workspace[rhs.id.uuidString]?.lastOpenedAt ?? .distantPast
                if a != b { return a > b }
            case .title:
                let order = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
            case .manual:
                let a = ranks[lhs.id] ?? Int.max
                let b = ranks[rhs.id] ?? Int.max
                if a != b { return a < b }
            case .added: break
            }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
