import Foundation

/// A validated, locally identified window. Persist this before publishing its first block.
public struct AIReflowPlan: Codable, Sendable, Equatable {
    public let version: Int
    public let windowID: UUID
    public let evidenceDigest: String
    public let requestConfigurationDigest: String
    public let blocks: [Block]

    public struct Block: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: Kind
        public let sourceSegments: [SourceSegment]
        public let objectRefs: [String]
        public var sourceIDs: [UUID] { sourceSegments.map(\.sourceID) }
    }

    public struct SourceSegment: Codable, Sendable, Equatable {
        public let sourceID: UUID
        public let startUTF16: Int
        public let endUTF16: Int
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case title, heading, paragraph
        case listItem = "list_item"
        case figureCaption = "figure_caption"
        case substantiveFootnote = "substantive_footnote"
        case displayFormula = "display_formula"
        case figure, table, code, bibliography
        case frontMatter = "front_matter"
        case preservedSource = "preserved_source"
    }
}

/// Explicitly supplied local image bytes; the service never fetches model-provided URLs.
public struct AIReflowImage: Sendable {
    public let sourceID: UUID
    public let data: Data
    public let mimeType: String
    public init(sourceID: UUID, data: Data, mimeType: String) {
        self.sourceID = sourceID
        self.data = data
        self.mimeType = mimeType
    }
}
