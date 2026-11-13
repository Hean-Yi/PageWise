import Foundation

public struct TextBlock: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourcePage: Int
    public var text: String
    public init(id: UUID = UUID(), sourcePage: Int, text: String) {
        self.id = id
        self.sourcePage = sourcePage
        self.text = text
    }
}

public struct BilingualBlock: Sendable {
    public let block: TextBlock
    public let translation: String?
    public init(block: TextBlock, translation: String?) {
        self.block = block
        self.translation = translation
    }
}

public struct PageArtifact: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var blockIDs: [UUID]
    public var sourcePage: Int
    public var relativePath: String
    public init(id: UUID = UUID(), blockIDs: [UUID], sourcePage: Int, relativePath: String) {
        self.id = id
        self.blockIDs = blockIDs
        self.sourcePage = sourcePage
        self.relativePath = relativePath
    }
}

public struct Paper: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var sourceURL: String?
    public var digest: String
    public var originalPath: String
    public var pageCount: Int
    public var blocks: [TextBlock]
    public var warnings: [String]
    public var canReflow: Bool
    public var previewPages: [PageArtifact] = []
    public var translatedPages: [PageArtifact] = []
    public var translations: [String: String] = [:]
    public var translatedBlockCount = 0
    public var addedAt = Date()
    public var summary = ""
    public var notePath: String?
    public var noteBaseline: String?
    public var savedDiscussion = ""
    public init(
        id: UUID = UUID(), title: String, digest: String, originalPath: String,
        pageCount: Int, blocks: [TextBlock], warnings: [String], canReflow: Bool
    ) {
        self.id = id
        self.title = title
        self.digest = digest
        self.originalPath = originalPath
        self.pageCount = pageCount
        self.blocks = blocks
        self.warnings = warnings
        self.canReflow = canReflow
    }
}

public struct Highlight: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var paperID: UUID
    public var pageKey: String
    public var pageIndex: Int
    public var text: String
    public var rects: [[Double]]
    public var createdAt = Date()
    public init(paperID: UUID, pageKey: String, pageIndex: Int, text: String, rects: [[Double]]) {
        self.paperID = paperID
        self.pageKey = pageKey
        self.pageIndex = pageIndex
        self.text = text
        self.rects = rects
    }
}

public struct Evidence: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var paperID: UUID?
    public var blockID: UUID?
    public var sourcePage: Int?
    public var notePath: String?
    public init(
        id: String, title: String, text: String, paperID: UUID? = nil, blockID: UUID? = nil,
        sourcePage: Int? = nil, notePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.paperID = paperID
        self.blockID = blockID
        self.sourcePage = sourcePage
        self.notePath = notePath
    }
}

public struct ChatTurn: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var paperID: UUID
    public var question: String
    public var selection: String
    public var answer: String
    public var evidence: [Evidence]
    public var createdAt = Date()
    public init(paperID: UUID, question: String, selection: String, answer: String, evidence: [Evidence]) {
        self.paperID = paperID
        self.question = question
        self.selection = selection
        self.answer = answer
        self.evidence = evidence
    }
}

public struct MemoryItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var text: String
    public var sourceID: UUID
    public var userEdited = false
    public var deleted = false
    public var createdAt = Date()
    public init(text: String, sourceID: UUID) {
        self.text = text
        self.sourceID = sourceID
    }
}

public struct ReadingEntry: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var paperID: UUID
    public var start: Date
    public var end: Date
    public var manual: Bool
    public init(paperID: UUID, start: Date, end: Date, manual: Bool = false) {
        self.paperID = paperID
        self.start = start
        self.end = end
        self.manual = manual
    }
}

public struct LibraryState: Codable, Sendable {
    public var version = 1
    public var papers: [Paper] = []
    public var highlights: [Highlight] = []
    public var chats: [ChatTurn] = []
    public var memories: [MemoryItem] = []
    public var reading: [ReadingEntry] = []
    public init() {}
}

public struct ModelSettings: Codable, Sendable {
    public var baseURL = "https://open.bigmodel.cn/api/paas/v4"
    public var model = ""
    public var temperature = 0.2
    public init() {}
}

public enum ReaderError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}
