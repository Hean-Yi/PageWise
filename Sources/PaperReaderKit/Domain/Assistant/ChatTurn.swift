import Foundation

public struct ChatTurn: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var paperID: UUID
    public var question: String
    public var selection: String
    public var answer: String
    public var evidence: [Evidence]
    /// A note lives in the same collection as manually made reading notes.
    public var readingNoteID: UUID?
    public var createdAt = Date()
    public init(paperID: UUID, question: String, selection: String, answer: String, evidence: [Evidence]) {
        self.paperID = paperID
        self.question = question
        self.selection = selection
        self.answer = answer
        self.evidence = evidence
    }
}
