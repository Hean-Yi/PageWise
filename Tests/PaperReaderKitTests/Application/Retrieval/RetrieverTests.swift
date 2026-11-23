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
