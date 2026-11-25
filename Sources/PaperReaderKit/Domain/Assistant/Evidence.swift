import Foundation

public struct Evidence: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var displayTitle: String { paperID == nil ? title : PaperTitle.display(title) }
    public var text: String
    public var paperID: UUID?
    public var blockID: UUID?
    public var sourcePage: Int?
    public var notePath: String?
    public var readingNoteID: UUID?
    public init(
        id: String, title: String, text: String, paperID: UUID? = nil, blockID: UUID? = nil,
        sourcePage: Int? = nil, notePath: String? = nil, readingNoteID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.paperID = paperID
        self.blockID = blockID
        self.sourcePage = sourcePage
        self.notePath = notePath
        self.readingNoteID = readingNoteID
    }
}
