import Foundation

public enum SearchTermMatches {
    // Keep identifiers, hyphenated terms, initials and language names such as C++ intact.
    private static let keywords = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:[\p{Pd}\u2212'’._/][\p{L}\p{N}][\p{L}\p{M}\p{N}]*)*(?:\+\+|#)?"#)
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// A standalone acronym, accession or DOI requests the named item. Similar vectors for
    /// different identifiers cannot establish an exact reference.
    public static func isIdentifierQuery(_ text: String) -> Bool {
        guard (2...160).contains(text.utf8.count), text.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            return false
        }
        if text.hasPrefix("10.") || text.lowercased().hasPrefix("doi:") || text.contains("doi.org/") {
            return PaperCandidate.queryDOI(text) != nil
        }
        if PaperCandidate.arxivIdentifier(text) != nil { return true }
        guard text.contains(where: \.isLetter) else { return false }
        let acronym = (3...16).contains(text.count) && text.uppercased() == text
        return acronym || (text.contains(where: \.isNumber) && text.contains(where: { "-_./".contains($0) }))
    }

    public static func ranges(in text: String, query: String?) -> [Range<String.Index>] {
        guard let query, !query.isEmpty, !text.isEmpty else { return [] }
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = input.prefix(4).lowercased()
        let doi = ["http", "doi:", "10."].contains(where: prefix.hasPrefix) ? PaperCandidate.queryDOI(input) : nil
        let terms: [String]
        if let doi {
            terms = [doi]
        } else {
            terms = keywords.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
                Range($0.range, in: input).map { String(input[$0]) }
            }
        }

        var hits: [Range<String.Index>] = []
        for term in Set(terms) {
            let parts = doi == nil ? term.split(whereSeparator: isDash) : [term[...]]
            guard let first = parts.first else { continue }
            var start = text.startIndex
            findNext: while start < text.endIndex,
                let match = text.range(of: first, options: options, range: start..<text.endIndex, locale: locale)
            {
                start = match.upperBound
                var end = match.upperBound
                for part in parts.dropFirst() {
                    let next = text[end...].firstIndex { !$0.isWhitespace && !isDash($0) } ?? text.endIndex
                    guard next > end,
                        let suffix = text.range(
                            of: part, options: options.union(.anchored), range: next..<text.endIndex, locale: locale)
                    else { continue findNext }
                    end = suffix.upperBound
                }
                guard !continuesWord(in: text, at: match.lowerBound), !continuesWord(in: text, at: end) else {
                    continue
                }
                hits.append(match.lowerBound..<end)
            }
        }

        var result: [Range<String.Index>] = []
        for hit in hits.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let previous = result.last,
                hit.lowerBound <= previous.upperBound
                    || text[previous.upperBound..<hit.lowerBound].allSatisfy({ $0.isWhitespace || isDash($0) })
            {
                result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, hit.upperBound)
            } else {
                result.append(hit)
            }
        }
        return result
    }

    private static func isDash(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.isDash == true
    }

    private static func continuesWord(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return false }
        func needsBoundary(_ c: Character) -> Bool {
            (c.isLetter || c.isNumber) && c.unicodeScalars.first?.properties.isIdeographic != true
        }
        return needsBoundary(text[text.index(before: index)]) && needsBoundary(text[index])
    }
}
