import Foundation

/// Durable evidence and accepted window. Draft text never enters this checkpoint.
public struct ReflowJob: Codable, Sendable, Equatable {
    public var id = UUID()
    public var sources: [TextBlock]
    /// nil denotes legacy fully extracted evidence. New jobs persist a page cursor atomically with sources.
    public var nextSourcePage: Int?
    /// Excluded metadata stays in sources and the original PDF, outside the reading sections.
    public var excludedSourceIDs: Set<UUID>?
    public var completedSourceIDs: Set<UUID> = []
    public var modelSettings: ModelSettings?
    public var acceptedPlan: AIReflowPlan?
    public var committedBlockIDs: Set<UUID> = []
    public var hasPresentedContent = false
    public var finished = false
    public var failure: String?
    public var createdAt = Date()
    public init(sources: [TextBlock]) { self.sources = sources }
}

/// Preserves the exact reading artifact to which existing user records refer.
public struct RetainedReading: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var blocks: [TextBlock]
    public var translations: [String: String]
    public var html: HTMLReadingArtifact?
    public var pages: [PageArtifact]
    public var translatedBlockCount: Int
    public init(paper: Paper) {
        blocks = paper.blocks
        translations = paper.translations
        html = paper.htmlReading
        pages = paper.translatedPages
        translatedBlockCount = paper.translatedBlockCount
    }
    public var readingPages: [PageArtifact] { html?.sections ?? pages }
    public func projecting(_ paper: Paper) -> Paper {
        var result = paper
        result.blocks = blocks
        result.translations = translations
        result.htmlReading = html
        result.translatedPages = pages
        result.translatedBlockCount = translatedBlockCount
        result.canReflow = true
        result.reflowJob = nil
        return result
    }
}
