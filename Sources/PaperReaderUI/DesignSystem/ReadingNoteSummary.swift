import Foundation

/// A bounded, plain-text sidebar label. The full note uses the reading editor's Markdown and math renderer.
@MainActor enum ReadingNoteSummary {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    private static let bodyCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    // Earlier close-reading formats put these field names in ordinary or bold paragraphs.
    private static let fieldNames: Set<String> = ["一句话概括", "段落作用", "通俗解释", "关键概念", "核心论点", "审读"]

    /// The notebook index leads with prose. Result cards elsewhere may use the heading as their label.
    static func bodyExcerpt(_ markdown: String) -> String {
        let prefix = String(markdown.prefix(4_096))
        let key = prefix as NSString
        if let cached = bodyCache.object(forKey: key) { return cached as String }
        var excerpt = ""
        if let parsed = try? AttributedString(markdown: prefix) {
            for (intent, range) in parsed.runs[\.presentationIntent] {
                guard intent?.components.first?.kind == .paragraph else { continue }
                let paragraph = parsed[range]
                guard
                    paragraph.runs.contains(where: {
                        $0.link == nil && paragraph[$0.range].characters.contains { !$0.isWhitespace }
                    })
                else { continue }
                let words = prose(in: paragraph)
                guard !words.isEmpty else { continue }
                excerpt = words.count > 180 ? String(words.prefix(179)) + "…" : words
                break
            }
        }
        bodyCache.setObject(excerpt as NSString, forKey: key)
        return excerpt
    }

    private static func prose(in paragraph: AttributedSubstring) -> String {
        let words = String(paragraph.characters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if fieldNames.contains(words) { return "" }
        if let colon = words.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            let label = words[..<colon].trimmingCharacters(in: .whitespaces)
            let body = words[words.index(after: colon)...]
            if fieldNames.contains(label) { return body.trimmingCharacters(in: .whitespaces) }
            // With no space after **标签：**, CommonMark can leave the emphasis markers as literal text.
            if label.hasPrefix("**"), body.hasPrefix("**"), fieldNames.contains(String(label.dropFirst(2))) {
                return body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
        }
        if let run = paragraph.runs.first, run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            let label = String(paragraph[run.range].characters)
            if fieldNames.contains(label), words.hasPrefix(label + " ") {
                return String(words.dropFirst(label.count + 1))
            }
        }
        return words
    }

    static func text(_ markdown: String) -> String {
        let prefix = String(markdown.prefix(640))
        if let cached = cache.object(forKey: prefix as NSString) { return cached as String }
        let line =
            prefix.split(whereSeparator: \.isNewline).lazy.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("~~~") && $0 != "---" } ?? ""
        let parsed = try? AttributedString(markdown: line)
        let value = excerpt(parsed.map { String($0.characters) } ?? line)
        cache.setObject(value as NSString, forKey: prefix as NSString)
        return value
    }

    static func excerpt(_ text: String) -> String {
        let normalized = text.prefix(640).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.count > 80 ? String(normalized.prefix(79)) + "…" : normalized
    }
}
