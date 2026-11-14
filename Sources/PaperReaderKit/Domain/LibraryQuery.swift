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

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recent, added, title
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recent: "最近打开"
        case .added: "添加时间"
        case .title: "标题"
        }
    }
}

public enum LibraryQuery {
    public static func papers(
        in state: LibraryState, collection: LibraryCollection = .all, query: String = "", sort: LibrarySort = .recent
    ) -> [Paper] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let finishedIDs = Set(
            state.papers.filter {
                collection == .all
                    && LibraryCollection.finished.includes(
                        state.workspace[$0.id.uuidString] ?? PaperWorkspace(), for: $0)
            }.map(\.id))
        return state.papers.filter { paper in
            let preferences = state.workspace[paper.id.uuidString] ?? PaperWorkspace()
            return collection.includes(preferences, for: paper)
                && terms.allSatisfy { paper.title.localizedStandardContains($0) }
        }.sorted { lhs, rhs in
            let leftFinished = finishedIDs.contains(lhs.id)
            let rightFinished = finishedIDs.contains(rhs.id)
            if leftFinished != rightFinished { return !leftFinished }
            switch sort {
            case .recent:
                let a = state.workspace[lhs.id.uuidString]?.lastOpenedAt ?? .distantPast
                let b = state.workspace[rhs.id.uuidString]?.lastOpenedAt ?? .distantPast
                if a != b { return a > b }
            case .title:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .added: break
            }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
