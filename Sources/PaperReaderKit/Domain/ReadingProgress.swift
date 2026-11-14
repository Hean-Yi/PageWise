import Foundation

/// Source-page progress, with completion retained until the user changes the reading status.
public enum ReadingProgress: Equatable, Sendable {
    case notStarted
    case reading(percent: Int?)
    case finished

    public static func resolve(paper: Paper, workspace: PaperWorkspace) -> ReadingProgress {
        switch workspace.status {
        case .unread: return .notStarted
        case .finished: return .finished
        case .reading:
            guard paper.pageCount > 0, let position = workspace.position,
                let page = PaperPageLocator.sourcePage(for: position, in: paper),
                page >= 0, page < paper.pageCount
            else { return .reading(percent: nil) }
            if page == paper.pageCount - 1 { return .finished }
            return .reading(percent: min(99, Int(Double(page + 1) / Double(paper.pageCount) * 100)))
        }
    }

    public var readingStatus: PaperReadingStatus {
        switch self {
        case .notStarted: .unread
        case .reading: .reading
        case .finished: .finished
        }
    }

    public var label: String {
        switch self {
        case .notStarted: "未开始"
        case .reading(let percent): percent.map { "读到 \($0)%" } ?? "在读"
        case .finished: "已读"
        }
    }

    public var fraction: Double? {
        switch self {
        case .notStarted: 0
        case .reading(let percent): percent.map { Double($0) / 100 }
        case .finished: 1
        }
    }
}
