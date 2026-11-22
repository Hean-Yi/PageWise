import Foundation

/// Original page-space line rectangles and PDFKit character ranges are scoped to the imported PDF digest.
public struct PDFSourceSentence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let pageIndex: Int
    public let rects: [[Double]]
    public let paragraphID: String
    public let characterRanges: [NSRange]

    public init(
        id: String, text: String, pageIndex: Int, rects: [[Double]], paragraphID: String,
        characterRanges: [NSRange] = []
    ) {
        self.id = id
        self.text = text
        self.pageIndex = pageIndex
        self.rects = rects
        self.paragraphID = paragraphID
        self.characterRanges = characterRanges
    }
}

public struct PDFSentenceExtraction: Sendable {
    public let sentences: [PDFSourceSentence]
    public let notice: String?
}
