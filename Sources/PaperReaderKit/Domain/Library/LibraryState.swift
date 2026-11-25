import Foundation

public struct LibraryState: Codable, Sendable {
    public static let currentVersion = 15
    public var version = currentVersion
    public var papers: [Paper] = []
    public var readingNotes: [ReadingNote] = []
    public var highlights: [Highlight] = []
    public var chats: [ChatTurn] = []
    public var memories: [MemoryItem] = []
    /// After a source paper is removed, only irreversible hashes of explicitly rejected propositions survive.
    var suppressedMemoryFingerprints: Set<String> = []
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
        case manualPaperIDs, preferredSort, readingNotes, suppressedMemoryFingerprints
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
        // v5 introduces optional structured blocks and retained source pages. Missing v1-v4
        // fields decode to nil; all published page IDs, annotations and preview records survive.
        // v6 adds optional HTML reading artifacts and text-range highlights. Old PDF IDs remain unchanged.
        // v7 adds independent reading notes; all existing annotation coordinates are preserved.
        readingNotes = storedVersion >= 7 ? try values.decode([ReadingNote].self, forKey: .readingNotes) : []
        // v8 adds optional on-demand reflow checkpoints and retained reading versions.
        // Legacy papers decode these fields as nil without changing their artifacts or annotations.
        // v9 drops PDF-conversion metadata. Replan only the unpublished suffix of
        // source jobs: old window digests included fields that are no longer decoded.
        if storedVersion < 9 {
            for index in papers.indices
            where papers[index].reflowJob?.supportsContinuation == true
                && papers[index].reflowJob?.finished == false
            {
                papers[index].reflowJob?.acceptedPlan = nil
                papers[index].reflowJob?.committedBlockIDs = []
            }
        }
        // v9 summaries were attached to the first checked passage. The report, not the editable
        // Markdown heading, identifies the summary. Historical highlights have no owner IDs.
        if storedVersion < 10 {
            let summaries = Dictionary(grouping: chats.filter { $0.closeReadingVersion != nil }, by: \.paperID)
                .mapValues { Set($0.compactMap(\.readingNoteID)) }
            for index in readingNotes.indices
            where summaries[readingNotes[index].paperID]?.contains(readingNotes[index].id) == true {
                readingNotes[index].placement = .documentEnd
                readingNotes[index].anchors = []
            }
        }
        if storedVersion == 11 { try migrateVersion11(from: decoder) }
        if storedVersion < 13 { recordLegacyStrokeMembers() }
        if storedVersion >= 14 {
            suppressedMemoryFingerprints =
                try values.decodeIfPresent(Set<String>.self, forKey: .suppressedMemoryFingerprints) ?? []
        }
        // v15 classifies only newly attributed preferences. Missing metadata on older
        // memories stays nil, preserving evidence ownership and all tombstones.
        try validateMemorySuppression()
        try validateOrdering()
        try validateShelves()
        version = Self.currentVersion
    }

    func validateMemorySuppression() throws {
        guard
            suppressedMemoryFingerprints.allSatisfy({ hash in
                hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            })
        else { throw ReaderError.message("书库记忆指纹格式无效，原资料已保留。") }
    }
}
