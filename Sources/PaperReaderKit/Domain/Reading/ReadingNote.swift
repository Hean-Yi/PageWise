import Foundation

/// Text offsets are relative to the language stream; objects retain their whole-object label.
public struct NoteAnchor: Codable, Sendable, Equatable, Hashable {
    public var key: String
    public var target: String
    public var text: String
    public var start: Int
    public var end: Int
    public init(key: String, target: String, text: String, start: Int, end: Int) {
        self.key = key
        self.target = target
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct ReadingNote: Identifiable, Codable, Sendable, Equatable {
    public enum Placement: String, Codable, Sendable {
        case documentEnd
    }
    public var id: UUID
    public var paperID: UUID
    public var contentVersion: String
    public var anchors: [NoteAnchor]
    /// A pre-v13 editor sometimes saved just one fragment of a multi-fragment mark.
    /// Display can recover its sibling ranges after checking the PDF. The stored anchors remain authoritative.
    public var legacyStrokeMemberID: UUID?
    public var citations: [LocalPassageCitation]?
    /// Sources supplied to the Agent when it wrote this note. The reader can always open the saved text.
    public var backgroundSources: ChatSourceVersions?
    public var markdown: String
    public var dimension: CloseReadingDimension?
    /// Ordinary notes use their passage anchors. Document summaries own their citations separately.
    public var placement: Placement?
    public var isDocumentSummary: Bool { placement == .documentEnd }
    public var createdAt: Date
    public var modifiedAt: Date
    /// Soft deletion supports undo without discarding the user's source text.
    public var deletedAt: Date?
    public init(id: UUID = UUID(), paperID: UUID, contentVersion: String, anchors: [NoteAnchor], markdown: String) {
        self.id = id
        self.paperID = paperID
        self.contentVersion = contentVersion
        self.anchors = anchors
        self.markdown = markdown
        createdAt = Date()
        modifiedAt = createdAt
    }
}
