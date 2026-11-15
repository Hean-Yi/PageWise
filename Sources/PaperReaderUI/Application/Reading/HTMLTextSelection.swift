import Foundation

public struct HTMLTextSelection: Sendable, Equatable {
    public var pageKey: String
    public var text: String
    public var start: Int
    public var end: Int
    public var target: String = "source"
    public var highlightStart: Int?
    public var highlightEnd: Int?
}

extension ReaderModel {
    func captureHTMLSelection(_ parts: [HTMLTextSelection]) {
        guard usesHTMLReading else { return }
        var text = ""
        var previousKey: String?
        for part in parts {
            if let previousKey, previousKey != part.pageKey { text += "\n\n" }
            text += part.target.hasPrefix("object:") ? " \(part.text) " : part.text
            previousKey = part.pageKey
        }
        captureSelection(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            rects: [], page: parts.first.flatMap { pageKeys.firstIndex(of: $0.pageKey) } ?? visiblePage)
        htmlSelection = parts
        selectionHTMLRange = parts.first.map { [$0.start, $0.end] }
    }
}
