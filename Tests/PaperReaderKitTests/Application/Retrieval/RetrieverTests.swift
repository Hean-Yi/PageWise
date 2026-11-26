import Foundation
import Testing

@testable import PaperReaderKit

@Test func currentPaperEvidenceComesFirst() {
    let current = Paper(
        title: "Current", digest: "a", originalPath: "a.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Attention query and key explanation")], warnings: [], canReflow: true)
    let note = Evidence(
        id: "", title: "Other", text: "An attention observation.", paperID: UUID(), readingNoteID: UUID())
    let hits = Retriever.context(
        question: "attention", selection: "query", current: current, notes: [], readingNotes: [note])
    #expect(hits.first?.paperID == current.id && hits.last?.readingNoteID == note.readingNoteID)
    #expect(Set(hits.map(\.id)).count == hits.count)
}

@Test func selectedLateBlockCannotBeCrowdedOut() {
    var blocks = (0..<30).map {
        TextBlock(sourcePage: $0, text: String(repeating: "attention background text ", count: 100))
    }
    let chosen = TextBlock(sourcePage: 30, text: "CRITICAL_SELECTED_EVIDENCE explains the theorem.")
    blocks.append(chosen)
    let paper = Paper(
        title: "Long", digest: "long", originalPath: "long.pdf", pageCount: 31, blocks: blocks, warnings: [],
        canReflow: true)
    let context = Retriever.context(
        question: "attention", selection: "CRITICAL_SELECTED_EVIDENCE", current: paper, notes: [])
    #expect(context.first?.blockID == chosen.id)
}

@Test func translatedSelectionUsesSourceAnchor() {
    let early = TextBlock(sourcePage: 0, text: String(repeating: "attention ", count: 4000))
    let selected = TextBlock(sourcePage: 20, text: "The final ablation measures generalization.")
    let paper = Paper(
        title: "Long", digest: "long", originalPath: "long.pdf", pageCount: 21, blocks: [early, selected], warnings: [],
        canReflow: true)
    let hits = Retriever.context(
        question: "解释", selection: "最后的消融实验", current: paper, notes: [], selectedBlockIDs: [selected.id])
    #expect(hits.first?.blockID == selected.id)
}

private struct TargetSemanticEncoder: SemanticTextEncoder {
    var identifier: String { "fixture-target-semantics" }
    func isInstalled() async -> Bool { true }
    func retrievalQuery(_ text: String) async throws -> (vector: [Float], minimum: Float)? {
        (text.contains("目标语义") ? [1, 0] : [0, 1], 0.5)
    }
    func encode(_ texts: [String], as role: SemanticTextRole) async throws -> [[Float]] {
        texts.map { $0.contains("THE_TARGET") ? [1, 0] : [0, 1] }
    }
}

@Test func currentPaperHybridRetrievalUsesSemanticMatchesForZeroLexicalOverlap() async throws {
    let filler = (0..<4).map {
        TextBlock(sourcePage: $0, text: String(repeating: "unrelated background prose ", count: 200))
    }
    let target = TextBlock(sourcePage: 9, text: "THE_TARGET passage explains the result.")
    let paper = Paper(
        title: "Hybrid", digest: "hybrid", originalPath: "hybrid.pdf", pageCount: 10,
        blocks: filler + [target], warnings: [], canReflow: true)
    let index = SemanticPassageIndex(encoder: TargetSemanticEncoder(), minimumScore: 0.5)
    try await index.prepare(
        paper.blocks.map { SemanticPassage(sourceID: $0.id, text: String($0.text.prefix(900))) })
    let hits = await Retriever.context(
        question: "目标语义是什么？", selection: "", current: paper, notes: [], semantic: index)
    #expect(hits.first?.blockID == target.id)
    let lexical = Retriever.context(
        question: "目标语义是什么？", selection: "", current: paper, notes: [])
    #expect(lexical.first?.blockID != target.id)
}
