import Foundation

public struct ChatTurn: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var paperID: UUID
    public var question: String
    public var selection: String
    public var answer: String
    /// Provider reasoning shown while the answer streams; nil when the model returns none.
    public var reasoning: String?
    /// Human-readable summary of tool calls executed during this turn, preserved for review.
    public var toolTrace: [String]?
    public var evidence: [Evidence]
    /// Absent on legacy turns, whose supplied background cannot be reconstructed safely.
    public var backgroundSources: ChatSourceVersions?
    /// IDs of preferences provided directly in this turn, independent of inherited history.
    public var suppliedPreferenceIDs: [UUID]?
    /// A note lives in the same collection as manually made reading notes.
    public var readingNoteID: UUID?
    public var closeReadingVersion: String?
    public var closeReadingNoteIDs: [UUID]?
    public var createdAt = Date()
    public init(paperID: UUID, question: String, selection: String, answer: String, evidence: [Evidence]) {
        self.paperID = paperID
        self.question = question
        self.selection = selection
        self.answer = answer
        self.evidence = evidence
        self.backgroundSources = .init()
    }
}
