import Foundation

/// A bounded, plain-text sidebar label. The full note uses the reading editor's Markdown and math renderer.
@MainActor enum ReadingNoteSummary {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

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
