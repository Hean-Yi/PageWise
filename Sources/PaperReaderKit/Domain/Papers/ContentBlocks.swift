import Foundation

public struct TextBlock: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourcePage: Int
    public var text: String
    /// Ordered extraction spans survive window-plan cleanup and retain every source page.
    public var reflowProvenance: [AIReflowSourceSpan]?
    public var texSource: TeXSourceAnchor?
    /// Sources within this page-sized group await model ordering; groups themselves cannot move.
    public var reflowOrderGroup: UUID?
    /// Normalized PDF coordinates (x, y, width, height), with a bottom-left origin.
    public var reflowBounds: [Double]?
    /// Small or marginal graphics may be classified as decoration by the model.
    public var reflowMayExclude: Bool?
    /// A validated model disposition, consumed before HTML publication.
    public var excludedFromReading: Bool?
    /// Present only until the corresponding fixed pages have been committed.
    public var richContent: RichContent?
    /// Complex PDF pages keep their original geometry inside the single reading result.
    public var preservesSourcePage: Bool?
    public var imageWarnings: [String]?
    public var hasImageFailure: Bool?
    public init(id: UUID = UUID(), sourcePage: Int, text: String) {
        self.id = id
        self.sourcePage = sourcePage
        self.text = text
    }
}

public struct RichContent: Codable, Sendable, Equatable {
    public var html: String
    public var translationInput: String
    public var mathematics: [String: String]
    public var mathDescriptions: [String: String]
    public var imageSizes: [PaperImageSize]? = nil
    public var isFigure: Bool? = nil
    /// Exporter glyph labels assist coverage checks only; they are not reading-order evidence.
    public var imageTextForCoverage: String? = nil
    public var figureCaption: FigureCaption? = nil
    /// Temporary during an explicit layout upgrade; released after this block publishes.
    public var restoredTranslationHTML: String? = nil

    public var requiresTranslation: Bool {
        !mathematics.keys.reduce(translationInput) { $0.replacingOccurrences(of: $1, with: "") }
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func validate(_ translation: String) throws {
        for marker in mathematics.keys {
            guard translation.components(separatedBy: marker).count == 2 else {
                throw ReaderError.message("译文未完整保留公式标记，已停止发布，可重试。")
            }
        }
        let remaining = mathematics.keys.reduce(translation) { $0.replacingOccurrences(of: $1, with: "") }
        guard !remaining.contains("[[MATH_") else {
            throw ReaderError.message("译文出现未知公式标记，未发布页面。")
        }
    }

    public func readableTranslation(_ translation: String) -> String {
        mathDescriptions.reduce(translation) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}

public struct FigureCaption: Codable, Sendable, Equatable {
    public var text: String
    public var html: String
    public var translationInput: String
    public var mathematics: [String: String]
    public var mathDescriptions: [String: String]
}

public struct PaperImageSize: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
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
