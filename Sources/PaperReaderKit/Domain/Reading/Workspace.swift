import Foundation

public enum PaperReadingStatus: String, Codable, CaseIterable, Sendable {
    case unread
    case reading
    case finished

    public var title: String {
        switch self {
        case .unread: "未读"
        case .reading: "在读"
        case .finished: "已读"
        }
    }
}

public struct ReaderPosition: Codable, Sendable, Equatable {
    public var mode: String
    public var pageKey: String
    public var pageIndex: Int

    public init(mode: String, pageKey: String, pageIndex: Int) {
        self.mode = mode
        self.pageKey = pageKey
        self.pageIndex = pageIndex
    }
}

public struct PaperWorkspace: Codable, Sendable, Equatable {
    public var isFavorite: Bool
    public var status: PaperReadingStatus
    public var lastOpenedAt: Date?
    public var position: ReaderPosition?

    public init(
        isFavorite: Bool = false, status: PaperReadingStatus = .unread,
        lastOpenedAt: Date? = nil, position: ReaderPosition? = nil
    ) {
        self.isFavorite = isFavorite
        self.status = status
        self.lastOpenedAt = lastOpenedAt
        self.position = position
    }
}

public struct PageBookmark: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var paperID: UUID
    public var pageKey: String
    public var pageIndex: Int
    public var mode: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), paperID: UUID, pageKey: String, pageIndex: Int,
        mode: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.pageKey = pageKey
        self.pageIndex = pageIndex
        self.mode = mode
        self.createdAt = createdAt
    }
}
