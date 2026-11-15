import Foundation

/// An original extraction range, independent of the merged output block's identity.
/// A negative page remains unknown; it is never inferred from neighboring sources.
public struct AIReflowSourceSpan: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let startUTF16: Int
    public let endUTF16: Int
    public let sourcePage: Int

    public init(sourceID: UUID, startUTF16: Int, endUTF16: Int, sourcePage: Int) {
        self.sourceID = sourceID
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.sourcePage = sourcePage
    }
}
