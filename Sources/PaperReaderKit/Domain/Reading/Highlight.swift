import Foundation

public struct Highlight: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var paperID: UUID
    public var pageKey: String
    public var pageIndex: Int
    public var text: String
    public var rects: [[Double]]
    /// UTF-16 start/end within the stable HTML section; nil for PDF geometry.
    public var textRange: [Int]?
    /// Source-only offsets and a shared paragraph highlight for its Chinese translation.
    /// Nil preserves the section-relative coordinates of existing HTML annotations.
    public var linksTranslation: Bool?
    public var createdAt = Date()
    public init(paperID: UUID, pageKey: String, pageIndex: Int, text: String, rects: [[Double]]) {
        self.paperID = paperID
        self.pageKey = pageKey
        self.pageIndex = pageIndex
        self.text = text
        self.rects = rects
    }
}
