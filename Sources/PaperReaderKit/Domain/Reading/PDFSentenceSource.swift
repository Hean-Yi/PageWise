import Foundation

/// Original page-space line rectangles and PDFKit character ranges are scoped to the imported PDF digest.
public struct PDFSourceSentence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let pageIndex: Int
    public let rects: [[Double]]
    /// The original extraction group is part of the on-device translation cache signature.
    public let paragraphID: String
    public let characterRanges: [NSRange]
    private let refinedParagraphID: String?

    public var readingParagraphID: String { refinedParagraphID ?? paragraphID }

    public init(
        id: String, text: String, pageIndex: Int, rects: [[Double]], paragraphID: String,
        characterRanges: [NSRange] = [], readingParagraphID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.pageIndex = pageIndex
        self.rects = rects
        self.paragraphID = paragraphID
        self.characterRanges = characterRanges
        self.refinedParagraphID = readingParagraphID == paragraphID ? nil : readingParagraphID
    }
}

public struct PDFSentenceExtraction: Sendable {
    public let sentences: [PDFSourceSentence]
    public let notice: String?
}
