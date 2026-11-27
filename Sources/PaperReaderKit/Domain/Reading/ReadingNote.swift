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
    public struct Revision: Identifiable, Codable, Sendable, Equatable {
        public enum Author: String, Codable, Sendable {
            case reader
            case ai
        }
        public var id = UUID()
        public var markdown: String
        public var modifiedAt: Date
        public var author: Author
        public var backgroundSources: ChatSourceVersions?
        public init(
            markdown: String, modifiedAt: Date, author: Author,
            backgroundSources: ChatSourceVersions? = nil
        ) {
            self.markdown = markdown
            self.modifiedAt = modifiedAt
            self.author = author
            self.backgroundSources = backgroundSources
        }
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
    /// Previous versions, newest last. Nil on notes that have never been revised by the agent.
    public var revisions: [Revision]?
    public init(id: UUID = UUID(), paperID: UUID, contentVersion: String, anchors: [NoteAnchor], markdown: String) {
        self.id = id
        self.paperID = paperID
        self.contentVersion = contentVersion
        self.anchors = anchors
        self.markdown = markdown
        createdAt = Date()
        modifiedAt = createdAt
    }

    /// A silent note-maintenance pass appends a version instead of discarding the reader's text.
    /// The newest version becomes current; older versions remain available for inspection.
    @discardableResult
    public mutating func applyAIRevision(
        _ replacement: String, at date: Date = Date(), sources: ChatSourceVersions? = nil
    ) -> Bool {
        guard deletedAt == nil, replacement != markdown else { return false }
        var history = revisions ?? []
        history.append(
            Revision(
                markdown: markdown, modifiedAt: modifiedAt,
                author: backgroundSources == nil ? .reader : .ai, backgroundSources: backgroundSources))
        if history.count > 20 { history.removeFirst(history.count - 20) }
        revisions = history
        markdown = replacement
        modifiedAt = date
        backgroundSources = sources
        return true
    }

    /// Restores a previous revision as the current note text, preserving the replaced version in history.
    @discardableResult
    public mutating func restoreRevision(_ revisionID: UUID, at date: Date = Date()) -> Bool {
        guard deletedAt == nil, let target = revisions?.first(where: { $0.id == revisionID }),
            target.markdown != markdown
        else { return false }
        var history = revisions ?? []
        history.append(
            Revision(
                markdown: markdown, modifiedAt: modifiedAt,
                author: backgroundSources == nil ? .reader : .ai, backgroundSources: backgroundSources))
        if history.count > 20 { history.removeFirst(history.count - 20) }
        revisions = history
        markdown = target.markdown
        modifiedAt = date
        backgroundSources = target.author == .reader ? nil : target.backgroundSources
        return true
    }
}
