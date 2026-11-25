import Foundation
import Testing

@testable import PaperReaderKit

@Test func researchQuestionUsesTheActualCompleteCurrentWordsAcrossLanguages() throws {
    let existing = String(repeating: "其他说明。", count: 100)
    let excerpt = "换到另一个 cohort，calibration 还能保持吗？"
    let question = "Calibration across a new cohort: does case mix explain the shift?"
    let proposal = try ResearchQuestionProposal(
        question: question, readerTurnID: UUID(), readerMessage: existing + excerpt + "明天继续。", quote: excerpt)
    #expect(proposal.item.librarySource == .reader(quote: excerpt))
    for (message, quote) in [
        (existing + excerpt, "作者长期研究 calibration。"),
        (excerpt, "calibration 还能保持吗？"),
        ("作者说：“" + excerpt + "”", excerpt),
        ("> " + excerpt + "\n重新核对这句话。", excerpt),
        (excerpt + "这次不要保存。", excerpt),
        ("Don't remember this. " + excerpt, excerpt),
        ("请帮我下载 calibration 论文。", "请帮我下载 calibration 论文。"),
    ] {
        #expect(throws: ReaderError.self) {
            try ResearchQuestionProposal(question: question, readerTurnID: UUID(), readerMessage: message, quote: quote)
        }
    }
    var state = LibraryState()
    var prior = proposal.item
    prior.correct(to: "我想追踪不同人群下的校准区间")
    state.memories = [prior]
    let restated = try ResearchQuestionProposal(
        question: "Does calibration hold within each cohort?", readerTurnID: UUID(), readerMessage: excerpt,
        quote: excerpt)
    #expect(!restated.isEligible(in: state, excluding: []))
    let duplicated = try ResearchQuestionProposal(
        question: question, readerTurnID: UUID(), readerMessage: excerpt, quote: excerpt)
    #expect(!duplicated.isEligible(in: state, excluding: []))
}

@Test func proposedQuestionsRejectStaleAndDerivedNoteEvidenceEvenAtPersistence() throws {
    let paper = Paper(
        title: "Calibration", digest: "demo", originalPath: "fixture.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let quote = "Calibration needs matched controls."
    let note = ReadingNote(paperID: paper.id, contentVersion: "test", anchors: [], markdown: quote)
    var state = LibraryState()
    state.readingNotes = [note]
    state.papers = [paper]
    let proposal = try ResearchQuestionProposal(
        question: "Which controls affect calibration?", quote: quote, registeredExcerpt: quote, note: note)
    #expect(proposal.isEligible(in: state, excluding: []))
    #expect(!proposal.isEligible(in: state, excluding: [paper.id]))
    #expect(throws: ReaderError.self) {
        try ResearchQuestionProposal(
            question: "Which controls affect calibration?", quote: "invented calibration quotation",
            registeredExcerpt: quote, note: note)
    }
    var report = ChatTurn(paperID: paper.id, question: "AI 精读", selection: "", answer: "AI", evidence: [])
    report.closeReadingNoteIDs = [note.id]
    state.chats = [report]
    #expect(!proposal.isEligible(in: state, excluding: []))
    state.chats = []
    state.readingNotes[0].modifiedAt = note.modifiedAt.addingTimeInterval(1)
    #expect(!proposal.isEligible(in: state, excluding: []))
}
