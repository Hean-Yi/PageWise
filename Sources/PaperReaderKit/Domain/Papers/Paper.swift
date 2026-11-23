import Foundation

public struct Paper: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var sourceURL: String?
    public var onlineSource: OnlinePaperSource?
    /// Older online imports may only have their provider URL or an existing source reflow checkpoint.
    public var usesSourceReflow: Bool {
        onlineSource != nil || sourceURL != nil || reflowJob?.supportsContinuation == true || hasPublishedSourceReading
    }
    public var hasPublishedSourceReading: Bool {
        guard htmlReading?.sections.isEmpty == false else { return false }
        if let route = reflowJob?.evidenceRoute { return route == "tex" || route == "html" }
        // Older snapshots can retain the published source anchors even when the job record is absent.
        if blocks.contains(where: {
            $0.texSource != nil || $0.reflowProvenance?.contains { $0.texSource != nil } == true
        }) {
            return true
        }
        // Early HTML records kept the verified same-version fallback in their warnings.
        return (onlineSource != nil || sourceURL != nil) && warnings.contains(OnlinePaperSource.sameVersionHTMLNotice)
            && !blocks.isEmpty && blocks.allSatisfy { $0.sourcePage < 0 }
    }
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
