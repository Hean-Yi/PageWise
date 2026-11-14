import Foundation

public struct TextBlock: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourcePage: Int
    public var text: String
    public init(id: UUID = UUID(), sourcePage: Int, text: String) {
        self.id = id
        self.sourcePage = sourcePage
        self.text = text
    }
}

public struct BilingualBlock: Sendable {
    public let block: TextBlock
    public let translation: String?
    public init(block: TextBlock, translation: String?) {
        self.block = block
        self.translation = translation
    }
}
