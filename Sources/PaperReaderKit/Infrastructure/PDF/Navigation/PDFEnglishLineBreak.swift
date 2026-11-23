import CoreFoundation
import Foundation
import NaturalLanguage

enum PDFEnglishLineBreak {
    case space, joined, removeHyphen

    static func separator(after text: String, before next: String, spellings: Set<String>) -> Self {
        guard let last = text.last, let first = next.first else { return .space }
        if last == "\u{ad}" { return .removeHyphen }
        if "([{".contains(last) || ".,;:!?)]}".contains(first) { return .joined }
        guard "-‐‑".contains(last) else { return .space }
        let left = text.dropLast().reversed().prefix { $0.isLetter || $0.isNumber }.reversed()
        let right = next.prefix { $0.isLetter || $0.isNumber }
        guard !left.isEmpty, !right.isEmpty else {
            return text.dropLast().last?.isWhitespace == true ? .space : .joined
        }
        let prefix = String(left).lowercased()
        let suffix = right.lowercased()
        // Suspended compounds ("short- and long-term") retain the space before the conjunction.
        if ["and", "or"].contains(suffix), next.dropFirst(right.count).first != "-" { return .space }
        guard last != "‑", first.isLowercase, left.allSatisfy(\.isLetter), right.allSatisfy(\.isLetter) else {
            return .joined
        }
        if spellings.contains(prefix + "-" + suffix) { return .joined }
        let word = prefix + suffix
        if spellings.contains(word) { return .removeHyphen }
        if [
            "tion", "tions", "ation", "ations", "uation", "ments", "ment", "tive", "tives", "ity", "ities",
            "ing", "ously", "ization",
        ].contains(suffix) {
            return .removeHyphen
        }
        // A permissible break in an attested English word helps when this paper uses it only once.
        // When both halves are words, the publisher may have intended a compound.
        guard word.utf8.count <= 64, word.utf8.allSatisfy({ (97...122).contains($0) }),
            let vocabulary = NLEmbedding.wordEmbedding(for: .english), vocabulary.contains(word),
            !(vocabulary.contains(prefix) && vocabulary.contains(suffix))
        else { return .joined }
        let boundary = prefix.utf8.count
        let locale = Locale(identifier: "en_US") as CFLocale
        let permitted = CFStringGetHyphenationLocationBeforeIndex(
            word as CFString, boundary + 1, CFRange(location: 0, length: word.utf8.count), 0, locale, nil)
        return permitted == boundary ? .removeHyphen : .joined
    }
}
