import Foundation

public enum ReaderError: Error, LocalizedError, Sendable {
    case message(String)
    case pdfTranslationIncomplete(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value), .pdfTranslationIncomplete(let value): value
        }
    }
}
