import Foundation

/// A conservative language-normalized key for "is this the same proposition?" It canonicalizes
/// common research phrasings (equal/matched compute, training time) but preserves numbers, negation
/// and word order. It is a duplicate guard, never a substitute for source verification.
public enum MemoryDedupKey {
    private static let replacements: [(String, String)] = [
        ("匹配", "equal"), ("相同", "equal"), ("等", "equal"), ("matched", "equal"), ("matching", "equal"),
        ("equal", "equal"), ("算力", "compute"), ("计算预算", "compute"), ("compute budget", "compute"),
        ("compute", "compute"), ("训练时长", "trainingtime"), ("训练时间", "trainingtime"),
        ("training duration", "trainingtime"), ("wall time", "trainingtime"),
        ("蒸馏", "distillation"), ("distillation", "distillation"),
        ("预算", "budget"), ("budget", "budget"),
        ("不", "not"), ("没有", "not"), ("未", "not"), ("并非", "not"), ("not", "not"), ("no", "not"),
    ]

    public static func key(_ text: String) -> String {
        var value = text
        if value.hasPrefix(MemoryItem.automaticPrefix) {
            value.removeFirst(MemoryItem.automaticPrefix.count)
        }
        if value.hasPrefix(MemoryItem.paperObservationPrefix) {
            value.removeFirst(MemoryItem.paperObservationPrefix.count)
        }
        value = value.folding(
            options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        for (from, to) in replacements {
            value = value.replacingOccurrences(of: from, with: to)
        }
        // Drop particles that commonly differ between paraphrases, while keeping word order.
        for filler in [
            "在", "后", "下", "时", "的", "了", "和", "与", "及", " in ", " the ", " a ", " an ", " under ", " after ",
        ] {
            value = value.replacingOccurrences(of: filler, with: "")
        }
        return value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

extension MemoryItem {
    public var deduplicationKey: String { MemoryDedupKey.key(text) }
}
