import CoreGraphics
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
    public let illustrations: [PDFReadingIllustration]
    public internal(set) var paragraphNotice: String?
    // Source-space lines which were not safely representable as translated prose.
    let unpairedBounds: [CGRect]
    let hasUnlocatedText: Bool
    private let picturedSentenceIDs: Set<String>

    public var paragraphSentences: [PDFSourceSentence] {
        picturedSentenceIDs.isEmpty ? sentences : sentences.filter { !picturedSentenceIDs.contains($0.id) }
    }

    init(
        sentences: [PDFSourceSentence], notice: String?, illustrations: [PDFReadingIllustration] = [],
        picturedSentenceIDs: Set<String> = [], unpairedBounds: [CGRect] = [], hasUnlocatedText: Bool = false
    ) {
        self.sentences = sentences
        self.notice = notice
        self.paragraphNotice = notice
        self.unpairedBounds = unpairedBounds
        self.hasUnlocatedText = hasUnlocatedText
        self.illustrations = illustrations
        self.picturedSentenceIDs = picturedSentenceIDs
    }
}

/// A rectangular table whose cell contents come directly from the PDF text layer.
public struct PDFReadingTable: Equatable, Sendable {
    public enum Baseline: String, Sendable { case normal, superscript, `subscript` }

    public struct Run: Equatable, Sendable {
        public let text: String
        public let baseline: Baseline
        public let bold: Bool
        public let italic: Bool

        public init(text: String, baseline: Baseline = .normal, bold: Bool = false, italic: Bool = false) {
            self.text = text
            self.baseline = baseline
            self.bold = bold
            self.italic = italic
        }
    }

    public struct StyledCell: Equatable, Sendable {
        /// Row zero is the table header.
        public let row: Int
        public let column: Int
        public let runs: [Run]

        public init(row: Int, column: Int, runs: [Run]) {
            self.row = row
            self.column = column
            self.runs = runs
        }
    }

    public struct HeaderCell: Equatable, Sendable {
        public let text: String
        public let column: Int
        public let rowSpan: Int
        public let columnSpan: Int
        public let runs: [Run]

        public init(text: String, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, runs: [Run] = []) {
            self.text = text
            self.column = column
            self.rowSpan = rowSpan
            self.columnSpan = columnSpan
            self.runs = runs
        }
    }

    public let header: [String]
    public let rows: [[String]]
    public let styledCells: [StyledCell]
    /// Physical rows of a verified grouped header. The flat header still identifies each leaf column.
    public let headerRows: [[HeaderCell]]
    /// Original PDF text rectangles for each physical cell, grouped header rows followed by body rows.
    public let sourceCellBounds: [[CGRect]]

    public init(
        header: [String], rows: [[String]], styledCells: [StyledCell] = [], headerRows: [[HeaderCell]] = [],
        sourceCellBounds: [[CGRect]] = []
    ) {
        self.header = header
        self.rows = rows
        self.styledCells = styledCells
        self.headerRows = headerRows
        self.sourceCellBounds = sourceCellBounds
    }
}

/// A transient view of one region of the original PDF. An unverified crop links to its caption.
public struct PDFReadingIllustration: Identifiable, Equatable, Sendable {
    public let id: String
    public enum Presentation: String, Sendable {
        case illustration, excerpt, originalPage, supplement
    }

    public let label: String
    public let pageIndex: Int
    public let sourceBounds: CGRect
    public let insertBeforeSentenceID: String?
    public let imagePNG: Data?
    public let table: PDFReadingTable?
    public let presentation: Presentation

    public init(
        id: String, label: String, pageIndex: Int, sourceBounds: CGRect, insertBeforeSentenceID: String?,
        imagePNG: Data?, table: PDFReadingTable? = nil, presentation: Presentation = .illustration
    ) {
        self.id = id
        self.label = label
        self.pageIndex = pageIndex
        self.sourceBounds = sourceBounds
        self.insertBeforeSentenceID = insertBeforeSentenceID
        self.imagePNG = imagePNG
        self.table = table
        self.presentation = presentation
    }
}
