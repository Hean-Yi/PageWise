import Foundation
import PaperReaderKit

struct NoteLinkRequest {
    let evidence: Evidence
    let quote: String
    let label: String
}

extension ReaderModel {
    func attachNoteLinks(to markdown: String, references: [NoteLinkRequest]) async throws
        -> (markdown: String, citations: [LocalPassageCitation])
    {
        let tokens = markdown.matches(of: /\{\{cite:([0-9]+)\}\}/)
        let expected = Set(references.indices.map { String($0 + 1) })
        guard Set(tokens.map { String($0.1) }) == expected else {
            if references.isEmpty {
                throw ReaderError.message("未提供 citations，markdown 中不应包含 {{cite:...}} 占位符。")
            }
            throw ReaderError.message(
                "笔记中的引用标记与 citations 不匹配：markdown 必须逐一包含 {{cite:1}} 到 {{cite:\(references.count)}} 占位符。")
        }
        var citations: [LocalPassageCitation] = []
        var replacements: [String] = []
        for ref in references {
            try Task.checkCancellation()
            guard ref.evidence.readingNoteID != nil else { throw ReaderError.message("请选择已检索的阅读笔记。") }
            let item = try await makeLocalPassageCitation(evidence: ref.evidence, quote: ref.quote)
            if !citations.contains(where: { $0.id == item.id }) { citations.append(item) }
            replacements.append(item.markdown(label: ref.label))
        }
        var result = ""
        var cursor = markdown.startIndex
        for match in tokens {
            guard let number = Int(match.1), replacements.indices.contains(number - 1) else {
                throw ReaderError.message("引用编号无效。")
            }
            result += markdown[cursor..<match.range.lowerBound] + replacements[number - 1]
            cursor = match.range.upperBound
        }
        result += markdown[cursor...]
        return (result, citations)
    }
}
