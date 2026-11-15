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
    public var id: UUID
    public var paperID: UUID
    public var contentVersion: String
    public var anchors: [NoteAnchor]
    public var markdown: String
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
