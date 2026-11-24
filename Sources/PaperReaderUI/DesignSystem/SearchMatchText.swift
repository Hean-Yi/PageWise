import PaperReaderKit
import SwiftUI

struct SearchMatchText: View {
    private let text: String
    private let matches: [Range<String.Index>]
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(_ text: String, query: String?) {
        self.init(text, matches: SearchTermMatches.ranges(in: text, query: query))
    }

    init(_ text: String, matches: [Range<String.Index>]) {
        self.text = text
        self.matches = matches
    }

    var body: Text {
        guard !matches.isEmpty else { return Text(verbatim: text) }
        var value = AttributedString(text)
        for match in matches {
            guard let range = Range(match, in: value) else { continue }
            value[range].backgroundColor = ReaderTheme.searchHighlight
            value[range].foregroundColor = ReaderTheme.ink
            if differentiateWithoutColor { value[range].underlineStyle = .single }
        }
        return Text(value)
    }
}
