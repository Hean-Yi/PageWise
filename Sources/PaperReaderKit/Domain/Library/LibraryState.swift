import Foundation

public struct LibraryState: Codable, Sendable {
    public static let currentVersion = 4
    public var version = currentVersion
    public var papers: [Paper] = []
    public var highlights: [Highlight] = []
    public var chats: [ChatTurn] = []
    public var memories: [MemoryItem] = []
    public var reading: [ReadingEntry] = []
    public var workspace: [String: PaperWorkspace] = [:]
    public var bookmarks: [PageBookmark] = []
    public var shelves: [Shelf] = []
    public var paperShelfIDs: [String: UUID] = [:]
    public var manualPaperIDs: [UUID] = []
    public var preferredSort: LibrarySort = .recent
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, papers, highlights, chats, memories, reading, workspace, bookmarks, shelves, paperShelfIDs
        case manualPaperIDs, preferredSort
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw ReaderError.message("书库版本不受支持，请使用兼容的应用版本。原有资料已保留。")
        }
        papers = try values.decode([Paper].self, forKey: .papers)
        highlights = try values.decode([Highlight].self, forKey: .highlights)
        chats = try values.decode([ChatTurn].self, forKey: .chats)
        memories = try values.decode([MemoryItem].self, forKey: .memories)
        reading = try values.decode([ReadingEntry].self, forKey: .reading)
        switch storedVersion {
        case 1:
            // v1 had no workspace metadata. Existing records and immutable page IDs stay untouched.
            workspace = [:]
            bookmarks = []
        default:
            workspace = try values.decode([String: PaperWorkspace].self, forKey: .workspace)
            bookmarks = try values.decode([PageBookmark].self, forKey: .bookmarks)
        }
        // v1/v2 did not contain topic shelves. Their paper and page records remain unchanged.
        if storedVersion >= 3 {
            shelves = try values.decode([Shelf].self, forKey: .shelves)
            paperShelfIDs = try values.decode([String: UUID].self, forKey: .paperShelfIDs)
        }
        // v4 adds custom ordering without changing paper, page or shelf identities.
        if storedVersion >= 4 {
            manualPaperIDs = try values.decode([UUID].self, forKey: .manualPaperIDs)
            preferredSort = try values.decode(LibrarySort.self, forKey: .preferredSort)
        }
        try validateOrdering()
        try validateShelves()
        version = Self.currentVersion
    }
}
