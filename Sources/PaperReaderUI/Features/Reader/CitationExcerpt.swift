import Foundation
import NaturalLanguage

/// Finds a short passage to display in a citation card. Its navigation target remains the saved evidence.
struct CitationExcerpt {
    private let selection: String
    private let terms: [String]

    init(question: String, selection: String) {
        self.selection = Self.singleLine(selection)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = question
        let words = Array(tokenizer.tokens(for: question.startIndex..<question.endIndex).prefix(40))
        let common: Set<String> = [
            "a", "an", "and", "are", "does", "for", "from", "how", "in", "is", "of", "on", "paper", "section",
            "that", "the", "their", "this", "to", "what", "with", "please", "explain", "according", "这篇", "论文", "原文",
            "什么", "如何", "为什么", "请问", "说明", "请", "的", "了", "用", "是", "在",
        ]
        var terms: [String] = []
        var seen = Set<String>()
        for size in [4, 3, 2, 1] where words.count >= size {
            for start in 0...(words.count - size) {
                let first = words[start]
                let last = words[start + size - 1]
                let term = Self.singleLine(String(question[first.lowerBound..<last.upperBound]))
                guard !common.contains(question[first].lowercased()), !common.contains(question[last].lowercased()),
                    term.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }),
                    size > 1 ? term.count >= 4 : term.count >= (term.allSatisfy(\.isASCII) ? 7 : 4),
                    seen.insert(term.lowercased()).inserted
                else { continue }
                terms.append(term)
            }
        }
        self.terms = terms
    }

    func preview(of evidence: String) -> String {
        let text = Self.singleLine(evidence)
        let fallback = String(text.prefix(160))
        guard !text.isEmpty else { return fallback }
        if !selection.isEmpty, let match = text.range(of: selection, options: .caseInsensitive) {
            return snippet(in: text, at: match, skipHeading: false)
        }
        for term in terms {
            if let match = wholePhrase(term, in: text) { return snippet(in: text, at: match, skipHeading: true) }
        }
        return fallback
    }

    private func wholePhrase(_ term: String, in text: String, within bounds: Range<String.Index>? = nil) -> Range<
        String.Index
    >? {
        let bounds = bounds ?? text.startIndex..<text.endIndex
        var start = bounds.lowerBound
        while let match = text.range(of: term, options: .caseInsensitive, range: start..<bounds.upperBound) {
            let joinsPrevious =
                term.first?.isASCII == true && match.lowerBound > text.startIndex
                && Self.wordCharacter(text[text.index(before: match.lowerBound)])
            let joinsNext =
                term.last?.isASCII == true && match.upperBound < text.endIndex
                && Self.wordCharacter(text[match.upperBound])
            if !joinsPrevious && !joinsNext { return match }
            start = match.upperBound
        }
        return nil
    }

    private func snippet(in text: String, at initialMatch: Range<String.Index>, skipHeading: Bool) -> String {
        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        func window(at match: Range<String.Index>) -> String {
            let sentence = sentences.tokenRange(at: match.lowerBound)
            var start = sentence.lowerBound
            if text.distance(from: start, to: match.lowerBound) > 40 { start = match.lowerBound }
            let end = text.index(start, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            return text[start..<min(end, max(sentence.upperBound, match.upperBound))].trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        let first = window(at: initialMatch)
        let phrase = String(text[initialMatch])
        guard skipHeading, first.count < phrase.count + 18 else { return first }
        // A table cell or heading may precede a fuller mention elsewhere in the same saved passage.
        var cursor = initialMatch.upperBound
        while let next = wholePhrase(phrase, in: text, within: cursor..<text.endIndex) {
            let candidate = window(at: next)
            if candidate.count >= phrase.count + 18 { return candidate }
            cursor = next.upperBound
        }
        return first
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}
