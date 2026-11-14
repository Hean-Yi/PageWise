import Foundation

/// Counts completed work in the current stage, not an estimate of elapsed time.
public struct PDFImportProgress: Sendable, Equatable {
    public let sequence: Int
    public let stage: String
    public let completed: Int
    public let total: Int?

    public init(sequence: Int, stage: String, completed: Int = 0, total: Int? = nil) {
        self.sequence = sequence
        self.stage = stage
        self.completed = completed
        self.total = total
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var label: String {
        guard let total else { return stage }
        return "\(stage) · \(completed) / \(total)"
    }
}
