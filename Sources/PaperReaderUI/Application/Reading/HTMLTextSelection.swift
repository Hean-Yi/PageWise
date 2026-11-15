import Foundation

public struct HTMLTextSelection: Sendable, Equatable {
    public var pageKey: String
    public var text: String
    public var start: Int
    public var end: Int
}

extension ReaderModel {
    func captureHTMLSelection(_ parts: [HTMLTextSelection]) {
        guard usesHTMLReading else { return }
        captureSelection(
            text: parts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n"),
            rects: [], page: parts.first.flatMap { pageKeys.firstIndex(of: $0.pageKey) } ?? visiblePage)
        htmlSelection = parts
        selectionHTMLRange = parts.first.map { [$0.start, $0.end] }
    }
}
