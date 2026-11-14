import Foundation

public enum ReaderError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}
