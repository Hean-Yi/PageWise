import Foundation

public struct PageArtifact: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var blockIDs: [UUID]
    public var sourcePage: Int
    public var relativePath: String
    public init(id: UUID = UUID(), blockIDs: [UUID], sourcePage: Int, relativePath: String) {
        self.id = id
        self.blockIDs = blockIDs
        self.sourcePage = sourcePage
        self.relativePath = relativePath
    }
}
