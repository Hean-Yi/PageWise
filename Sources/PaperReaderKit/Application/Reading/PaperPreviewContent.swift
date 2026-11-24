import Foundation

/// Reading material available on this device. Opening the cover never generates text.
public struct PaperPreviewContent: Equatable, Sendable {
    public var abstract: String?
    public var isChineseAbstract: Bool
    public var oneSentence: String?

    public init(abstract: String? = nil, isChineseAbstract: Bool = false, oneSentence: String? = nil) {
        self.abstract = abstract
        self.isChineseAbstract = isChineseAbstract
        self.oneSentence = oneSentence
    }
}

enum AbstractPassage {
    struct Part: Codable, Sendable {
        var text: String
        var paragraph: String
        var key: String
        var isSectionHeading = false
    }

    private static let label = try! NSRegularExpression(
        pattern: #"(?i)^(?:abstract|摘\s*要)(?:\s*[:：.—–-]\s*|\s*\n\s*|\s*$)"#)
    private static let end = try! NSRegularExpression(
        pattern:
            #"(?i)^(?:(?:[1-9]\d*(?:\.\d+)*|[ivx]+)[.)]?\s+)?(?:introduction|引言|绪论|前言)\s*[.:：]?$|^(?i:keywords?|key\s+words|index\s+terms|关键词|CCS concepts|ACM reference format)(?:\s*[:：.—–-]|\s*$)|^(?:[1-9]\d*(?:\.\d+)*|[IVX]+)[.)]?\s+\p{Lu}[^!?。？！]{0,90}(?<!\.)$"#
    )

    private static let frontMatterEnd = try! NSRegularExpression(
        pattern:
            #"(?i)^(?:date|correspondence|corresponding author|author legend)\s*[:：]|^(?:fig(?:ure)?\.?|table)\s+\d+[.:：](?:\s|$)"#
    )

    static func withoutLabel(_ value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        if let match = label.firstMatch(in: value, range: range), let start = Range(match.range, in: value) {
            return value[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // PDF text layers can omit the visual separator between a bold label and regular prose.
        // Require a sentence after such a label so a title like "Abstract Interpretation" stays a title.
        if value.count >= 28, value.contains(where: { ".!?。！？".contains($0) }),
            let prefix = value.range(
                of: #"^(?:[Aa]bstract|ABSTRACT)\s+(?=\p{Lu})|^摘\s*要\s*(?=\p{Han})"#,
                options: .regularExpression)
        {
            return String(value[prefix.upperBound...])
        }
        return nil
    }

    static func ends(at value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return end.firstMatch(in: value, range: range) != nil
            || frontMatterEnd.firstMatch(in: value, range: range) != nil
    }

    /// Only consider text following an explicit abstract marker; an unlabelled introduction is not an abstract.
    static func locate(_ parts: [Part]) -> (parts: [Part], closed: Bool)? {
        var started = false
        var result: [Part] = []
        var length = 0
        for var part in parts {
            let text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !started {
                guard let body = withoutLabel(text) else { continue }
                started = true
                part.text = body
            } else {
                part.text = text
                if part.isSectionHeading || ends(at: text) {
                    return (result, true)
                }
            }
            guard !part.text.isEmpty else { continue }
            length += part.text.utf8.count
            guard length <= 48_000 else { break }
            result.append(part)
        }
        return started ? (result, false) : nil
    }

    /// Map an independently identified abstract back to whole, consecutive source blocks for translation.
    static func matching(_ reference: String, in parts: [Part]) -> [Part]? {
        func comparable(_ text: String) -> String {
            let lettersJoined = text.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(
                of: #"(?<=\p{L})[-‐‑]\s*(?=\p{L})"#, with: "", options: .regularExpression)
            // Keep mathematical signs, percentages and decimal separators when pairing a translation.
            return lettersJoined.filter { !$0.isWhitespace && $0 != "\u{00ad}" }
        }
        let target = comparable(reference)
        guard target.count >= 32 else { return nil }
        let candidates = parts.map { part -> (Part, String) in
            var part = part
            part.text = withoutLabel(part.text) ?? part.text
            return (part, comparable(part.text))
        }
        for start in candidates.indices {
            let first = candidates[start].1
            guard !first.isEmpty, target.hasPrefix(first) else { continue }
            var matched = ""
            for end in start..<candidates.endIndex {
                let fragment = candidates[end].1
                guard !fragment.isEmpty else { break }
                matched += fragment
                if matched == target { return candidates[start...end].map(\.0) }
                if !target.hasPrefix(matched) { break }
            }
        }
        return nil
    }

    static func display(_ parts: [Part], translated: [String: String]) -> PaperPreviewContent? {
        guard !parts.isEmpty else { return nil }
        let chinese = parts.map { part -> String? in
            guard let raw = translated[part.key] else { return nil }
            let value = withoutLabel(raw) ?? raw
            return value.isEmpty ? nil : value
        }
        let localized = chinese.allSatisfy { $0 != nil } && containsChinese(chinese.compactMap { $0 }.joined())
        var paragraphs: [String] = []
        for (index, part) in parts.enumerated() {
            let value = localized ? (chinese[index] ?? part.text) : part.text
            if index == 0 || part.paragraph != parts[index - 1].paragraph {
                paragraphs.append(value)
            } else {
                paragraphs[paragraphs.count - 1] += (localized ? "" : " ") + value
            }
        }
        let value = paragraphs.joined(separator: "\n\n")
        return .init(abstract: value, isChineseAbstract: localized || containsChinese(value))
    }

    static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.lazy.filter { (0x3400...0x9FFF).contains($0.value) }.prefix(3).count == 3
    }
}
