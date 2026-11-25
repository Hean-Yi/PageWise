import Foundation
import NaturalLanguage

public enum PreviewTakeaway {
    public static func fromNotebook(_ markdown: String) -> String? {
        var heading = ""
        var legacy: String?
        for line in markdown.prefix(40_000).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                heading = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            if heading == "一句话概括", let value = firstSentence(in: text) { return value }
            if legacy == nil, ["论点", "结论", "核心论点", "核心结论", "主要发现", "作者主张"].contains(heading) {
                legacy = firstSentence(in: text)
            }
        }
        return legacy
    }

    // Some older notes begin by labelling the passage before explaining its subject.
    // Match a complete editorial sentence only, so a concrete claim may start with “本文”.
    private static let editorialLead =
        #"^(?:这(?:里|一段|一节|句话|一部分)?(?:正|就)?是|(?:本(?:文|段|节)|这(?:一)?(?:节|段)|作者)(?:在(?:这里|此处|本节|本段))?(?:介绍|提出|讨论|阐述|说明|指出|总结|概括)了?)(?:本文|本篇(?:论文)?|全文|作者|这篇论文|论文)?的?(?:一个|一项)?(?:最|非常)?(?:核心|关键|重要|主要|基本)*(?:的)?(?:研究|设计|实验|方法)?(?:问题|观点|论点|结论|思路|贡献|方法|发现|依据)[。！.!]?$"#

    public static func firstSentence(in markdown: String) -> String? {
        for raw in markdown.prefix(1_200).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("["), !line.hasPrefix(">"), !line.hasPrefix("!"),
                !line.hasPrefix("$$"), !line.hasPrefix("\u{60}\u{60}\u{60}"), !line.contains("paperreader://")
            else { continue }
            var value = (try? AttributedString(markdown: line)).map { String($0.characters) } ?? line
            value = value.replacingOccurrences(
                of: #"^(?:段落作用|通俗解释|核心论点|一句话概括)[\s:：]+"#, with: "", options: .regularExpression)
            guard !value.isEmpty else { continue }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = value
            var selected: String?
            tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
                let candidate = value[range].trimmingCharacters(in: .whitespacesAndNewlines)
                guard (6...280).contains(candidate.count),
                    candidate.range(of: editorialLead, options: .regularExpression) == nil
                else { return true }
                selected = candidate
                return false
            }
            if let selected { return selected }
        }
        return nil
    }
}
