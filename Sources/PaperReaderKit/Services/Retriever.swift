import Foundation
import NaturalLanguage

public enum Retriever {
    public static func context(
        question: String, selection: String, current: Paper, others: [Paper], notes: [Evidence],
        selectedBlockIDs: Set<UUID> = []
    ) -> [Evidence] {
        let terms = tokens(question + " " + selection)
        func rank(_ text: String) -> Double {
            let words = tokens(text)
            return Double(words.intersection(terms).count) / sqrt(Double(max(1, words.count)))
        }
        let pinned = current.blocks.indices.filter { index in
            selectedBlockIDs.contains(current.blocks[index].id)
                || (!selection.isEmpty && current.blocks[index].text.contains(selection))
        }
        let total = current.blocks.reduce(0) { $0 + $1.text.count }
        var indices = pinned
        func add(_ index: Int) {
            if current.blocks.indices.contains(index), !indices.contains(index) { indices.append(index) }
        }
        for index in pinned {
            add(index - 1)
            add(index + 1)
        }
        if total <= 18_000 {
            for index in current.blocks.indices { add(index) }
        } else {
            let ranked = current.blocks.indices.sorted {
                let a = rank(current.blocks[$0].text)
                let b = rank(current.blocks[$1].text)
                return a == b ? $0 < $1 : a > b
            }
            for index in ranked.prefix(12) { add(index) }
            add(0)
        }
        let ordered = indices.map { current.blocks[$0] }
        var result: [Evidence] = []
        var used = 0
        for block in ordered where used < 18_000 {
            let budget = 18_000 - used
            let text: String
            if block.text.count > budget, !selection.isEmpty, let match = block.text.range(of: selection) {
                let start = block.text.index(
                    match.lowerBound,
                    offsetBy: -min(500, block.text.distance(from: block.text.startIndex, to: match.lowerBound)))
                text = String(block.text[start...].prefix(budget))
            } else {
                text = String(block.text.prefix(budget))
            }
            result.append(
                Evidence(
                    id: "", title: current.title, text: text, paperID: current.id, blockID: block.id,
                    sourcePage: block.sourcePage))
            used += text.count
        }
        var support =
            others.filter { $0.id != current.id }.flatMap { paper in
                paper.blocks.map {
                    Evidence(
                        id: "", title: paper.title, text: $0.text, paperID: paper.id, blockID: $0.id,
                        sourcePage: $0.sourcePage)
                }
            } + notes
        support = support.filter { rank($0.text) > 0 }.sorted { rank($0.text) > rank($1.text) }
        for var hit in support.prefix(4) {
            hit.text = String(hit.text.prefix(1200))
            result.append(hit)
        }
        return result.enumerated().map { index, hit in
            var value = hit
            value.id = "S\(index + 1)"
            return value
        }
    }

    public static func tokens(_ value: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value.lowercased()
        var words: Set<String> = []
        tokenizer.enumerateTokens(in: tokenizer.string!.startIndex..<tokenizer.string!.endIndex) { range, _ in
            words.insert(String(tokenizer.string![range]))
            return true
        }
        return words
    }
}
