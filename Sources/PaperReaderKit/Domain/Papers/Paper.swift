import Foundation

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
    public var htmlReading: HTMLReadingArtifact?
    public var reflowJob: ReflowJob?
    public var retainedReadings: [RetainedReading]?
    public var deferredReflow: Bool?
    /// Stable reading anchors; HTML sections and legacy PDF pages share navigation semantics.
    public var readingPages: [PageArtifact] { htmlReading?.sections ?? translatedPages }
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
