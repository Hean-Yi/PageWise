import Foundation

public struct MemoryItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var text: String
    public var sourceID: UUID
    public var userEdited = false
    public var deleted = false
    public var createdAt = Date()
    public init(text: String, sourceID: UUID) {
        self.text = text
        self.sourceID = sourceID
    }
}
