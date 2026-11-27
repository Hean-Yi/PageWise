import Foundation
import NaturalLanguage

/// A conservative, word-boundary-safe language-normalized key for "is this the same proposition?"
/// It canonicalizes common research phrasings (equal/matched compute, training time) using whole
/// tokens so Chinese multi-character words (e.g. 上下文, 下降, 不等式) are never corrupted, while
/// preserving numbers, comparison operators, negation and word order.
public enum MemoryDedupKey {
    private static let phraseReplacements: [(String, String)] = [
        ("compute budget", " compute "),
        ("training duration", " trainingtime "),
        ("wall time", " trainingtime "),
        ("计算预算", " compute "),
        ("训练时长", " trainingtime "),
        ("训练时间", " trainingtime "),
        ("等算力", " equal compute "),
        ("等预算", " equal budget "),
    ]

    private static let tokenReplacements: [String: String] = [
        "匹配": "equal", "相同": "equal", "同等": "equal", "matched": "equal", "matching": "equal", "equal": "equal",
        "算力": "compute", "compute": "compute",
        "蒸馏": "distillation", "distillation": "distillation",
        "预算": "budget", "budget": "budget",
        "不": "not", "没有": "not", "未": "not", "并非": "not", "not": "not", "no": "not",
    ]

    private static let fillerTokens: Set<String> = [
        "在", "后", "下", "时", "的", "了", "和", "与", "及", "in", "the", "a", "an", "under", "after",
    ]

    private static let scriptRuns = try! NSRegularExpression(pattern: #"\p{Han}+|[<>≤≥=]+|[^\p{Han}<>≤≥=]+"#)

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
        for (from, to) in phraseReplacements {
            value = value.replacingOccurrences(of: from, with: to)
        }
        let tokens = orderedTokens(in: value)
        var canonical: [String] = []
        canonical.reserveCapacity(tokens.count)
        for token in tokens {
            if fillerTokens.contains(token) { continue }
            canonical.append(tokenReplacements[token] ?? token)
        }
        return canonical.joined()
    }

    private static func orderedTokens(in text: String) -> [String] {
        let chinese = NLTokenizer(unit: .word)
        chinese.setLanguage(.simplifiedChinese)
        let other = NLTokenizer(unit: .word)
        var result: [String] = []
        let fullRange = NSRange(text.startIndex..., in: text)
        scriptRuns.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let run = String(text[range])
            if run.allSatisfy({ "<>≤≥=".contains($0) }) {
                result.append(run)
                return
            }
            guard run.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            let tokenizer = run.unicodeScalars.first?.properties.isIdeographic == true ? chinese : other
            tokenizer.string = run
            tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { tokenRange, _ in
                let token = String(run[tokenRange])
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    result.append(token)
                }
                return true
            }
        }
        return result
    }
}

extension MemoryItem {
    public var deduplicationKey: String { MemoryDedupKey.key(text) }
}
