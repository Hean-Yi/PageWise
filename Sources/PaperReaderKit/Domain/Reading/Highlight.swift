import Foundation

public struct Highlight: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var paperID: UUID
    public var pageKey: String
    public var pageIndex: Int
    public var text: String
    public var rects: [[Double]]
    /// Immutable HTML edition that owns the text range. Older annotations are located by page key.
    public var contentVersion: String?
    /// UTF-16 offsets in the identified HTML or translated PDF text target.
    public var textRange: [Int]?
    /// Optional UTF-16 offset on the immutable original PDF page for highlights created in reflow.
    public var pdfTextStart: Int?
    /// Versioned text target for a local PDF translation, independent of original page coordinates.
    public var pdfTranslationTarget: String?
    /// Source-only offsets and a shared paragraph highlight for its Chinese translation.
    /// Nil preserves the section-relative coordinates of existing HTML annotations.
    public var linksTranslation: Bool?
    /// Language-specific text coordinates or a stable shared-object index; nil retains legacy semantics.
    public var htmlTarget: String?
    public var color: AnnotationColor?
    public var style: AnnotationStyle?
    public var createdAt = Date()
    public init(paperID: UUID, pageKey: String, pageIndex: Int, text: String, rects: [[Double]]) {
        self.paperID = paperID
        self.pageKey = pageKey
        self.pageIndex = pageIndex
        self.text = text
        self.rects = rects
    }
}
