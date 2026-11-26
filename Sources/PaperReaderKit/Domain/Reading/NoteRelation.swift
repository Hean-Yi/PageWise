import Foundation

/// A rebuildable edge between two notes. It stores only identity, type and source revision;
/// excerpts are re-read from the current note when a context is assembled.
public struct NoteRelation: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case similar
        case conflict
        case duplicate
        case differentScope
    }

    public var id: String { sourceID.uuidString + "|" + targetID.uuidString + "|" + kind.rawValue }
    public let sourceID: UUID
    public let targetID: UUID
    public let kind: Kind
    public let overlap: Int
    public let targetModifiedAt: Date

    public init(sourceID: UUID, targetID: UUID, kind: Kind, overlap: Int, targetModifiedAt: Date) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.overlap = overlap
        self.targetModifiedAt = targetModifiedAt
    }
}
