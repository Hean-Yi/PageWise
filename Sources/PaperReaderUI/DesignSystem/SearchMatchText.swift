import PaperReaderKit
import SwiftUI

struct SearchMatchText: View {
    private let text: String
    private let query: String?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(_ text: String, query: String?) {
        self.text = text
        self.query = query
    }

    var body: Text {
        let ranges = SearchTermMatches.ranges(in: text, query: query)
        guard !ranges.isEmpty else { return Text(verbatim: text) }
        var value = AttributedString(text)
        for match in ranges {
            guard let range = Range(match, in: value) else { continue }
            value[range].backgroundColor = ReaderTheme.searchHighlight
            value[range].foregroundColor = ReaderTheme.ink
            if differentiateWithoutColor { value[range].underlineStyle = .single }
        }
        return Text(value)
    }
}
