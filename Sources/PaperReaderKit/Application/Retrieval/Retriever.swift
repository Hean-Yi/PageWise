import Foundation
import NaturalLanguage

public enum Retriever {
    public static func context(
        question: String, selection: String, current: Paper, notes: [Evidence], readingNotes: [Evidence] = [],
        selectedBlockIDs: Set<UUID> = [], originalPages: [Evidence] = []
    ) -> [Evidence] {
        context(
            question: question, selection: selection, current: current, notes: notes, readingNotes: readingNotes,
            selectedBlockIDs: selectedBlockIDs, originalPages: originalPages, semanticScores: [:])
    }

    /// Hybrid retrieval for the current paper. The lexical path still works without the bundled
    /// model; when E5 is installed its cross-language matches lift the blocks a Chinese question
    /// would otherwise score at zero against English prose.
    public static func context(
        question: String, selection: String, current: Paper, notes: [Evidence], readingNotes: [Evidence] = [],
        selectedBlockIDs: Set<UUID> = [], originalPages: [Evidence] = [],
        semantic: SemanticPassageIndex?
    ) async -> [Evidence] {
        var semanticScores: [UUID: Double] = [:]
        if let semantic, !current.blocks.isEmpty {
            let passages = current.blocks.prefix(2_000).map {
                SemanticPassage(sourceID: $0.id, text: String($0.text.prefix(900)))
            }
            let query = String((question + " " + selection).prefix(1_600))
            let matches =
                (try? await semantic.matches(
                    query, passages: passages, allowed: Set(passages.map(\.sourceID)), limit: 24)) ?? []
            for (rank, match) in matches.enumerated() {
                let boost = Double(matches.count - rank) / Double(max(1, matches.count))
                semanticScores[match.passage.sourceID] = max(
                    semanticScores[match.passage.sourceID] ?? 0, boost)
            }
        }
        return context(
            question: question, selection: selection, current: current, notes: notes, readingNotes: readingNotes,
            selectedBlockIDs: selectedBlockIDs, originalPages: originalPages, semanticScores: semanticScores)
    }

    private static func context(
        question: String, selection: String, current: Paper, notes: [Evidence], readingNotes: [Evidence],
        selectedBlockIDs: Set<UUID>, originalPages: [Evidence], semanticScores: [UUID: Double]
    ) -> [Evidence] {
        let terms = expandedTokens(question + " " + selection)
        func rank(_ text: String) -> Double {
            let words = expandedTokens(text)
            return Double(words.intersection(terms).count) / sqrt(Double(max(1, words.count)))
        }
        let pinned = current.blocks.indices.filter { index in
            selectedBlockIDs.contains(current.blocks[index].id)
                || (!selection.isEmpty && current.blocks[index].text.contains(selection))
        }
        let characterBudget = 18_000
        var total = 0
        for block in current.blocks {
            total += block.text.count
            if total > characterBudget { break }
        }
        var indices = pinned
        var included = Set(pinned)
        func add(_ index: Int) {
            if current.blocks.indices.contains(index), included.insert(index).inserted { indices.append(index) }
        }
        for index in pinned {
            add(index - 1)
            add(index + 1)
        }
        if total <= characterBudget {
            for index in current.blocks.indices { add(index) }
        } else {
            let scores = current.blocks.map {
                rank($0.text) + (semanticScores[$0.id] ?? 0)
            }
            let ranked = current.blocks.indices.sorted { lhs, rhs in
                scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
            }
            for index in ranked.prefix(12) { add(index) }
            add(0)
        }
        var result: [Evidence] = []
        var used = 0
        for index in indices {
            guard used < characterBudget else { break }
            let block = current.blocks[index]
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let budget = characterBudget - used
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
                    sourcePage: block.sourcePage >= 0 ? block.sourcePage : nil))
            used += text.count
        }
        if result.isEmpty {
            for var page in originalPages where page.paperID == current.id && used < characterBudget {
                page.text = String(page.text.prefix(characterBudget - used))
                result.append(page)
                used += page.text.count
            }
        }
        let vaultMatches = notes.map { (source: $0, score: rank($0.text)) }
            .filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(4)
        for var hit in readingNotes.prefix(5) + vaultMatches.map(\.source) {
            hit.text = String(hit.text.prefix(1200))
            result.append(hit)
        }
        return result.enumerated().map { index, hit in
            var value = hit
            value.id = "S\(index + 1)"
            return value
        }
    }

    // Language detection on a Chinese question plus an English paper title can discard nearly
    // every Chinese word. Tokenize each script run independently, retaining the original word tokenizer.
    private static let scriptRuns = try! NSRegularExpression(pattern: #"\p{Han}+|[^\p{Han}]+"#)

    /// Lexical tokens plus a small bilingual research vocabulary. This is the zero-download
    /// fallback for note/memory retrieval; it is not a substitute for a semantic model.
    public static func expandedTokens(_ value: String) -> Set<String> {
        let base = tokens(value)
        var result = base
        result.formUnion(LocalSemanticLexicon.phraseConcepts(in: value))
        for token in base {
            result.formUnion(LocalSemanticLexicon.concepts(for: token))
        }
        return result
    }

    public static func tokens(_ value: String) -> Set<String> {
        let text = value.lowercased()
        let chinese = NLTokenizer(unit: .word)
        chinese.setLanguage(.simplifiedChinese)
        let other = NLTokenizer(unit: .word)
        var words: Set<String> = []
        scriptRuns.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text),
                text[range].contains(where: { $0.isLetter || $0.isNumber })
            else { return }
            let run = String(text[range])
            let tokenizer = run.unicodeScalars.first?.properties.isIdeographic == true ? chinese : other
            tokenizer.string = run
            tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { token, _ in
                words.insert(String(run[token]))
                return true
            }
        }
        return words
    }
}
