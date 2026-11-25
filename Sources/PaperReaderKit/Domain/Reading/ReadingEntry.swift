import Foundation

public struct ReadingEntry: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var paperID: UUID
    public var start: Date
    public var end: Date
    public var manual: Bool
    public init(paperID: UUID, start: Date, end: Date, manual: Bool = false) {
        self.paperID = paperID
        self.start = start
        self.end = end
        self.manual = manual
    }
}
