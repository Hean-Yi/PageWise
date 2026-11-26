import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test @MainActor func translationCreatesOnePaperGroundedObservationMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var paper = Paper(
        title: "Observed Paper", digest: "observed", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    paper.summary = "A local abstract about matched compute."
    reader.state.papers = [paper]
    await reader.ensurePaperMemory(paperID: paper.id)
    let memory = try #require(reader.state.memories.first)
    #expect(memory.librarySource == .paper(paperID: paper.id))
    #expect(memory.text.contains(MemoryItem.paperObservationPrefix))
    #expect(memory.text.contains("matched compute"))
    let count = reader.state.memories.count
    await reader.ensurePaperMemory(paperID: paper.id)
    #expect(reader.state.memories.count == count)
    reader.deleteMemory(memory.id)
    await reader.ensurePaperMemory(paperID: paper.id)
    #expect(reader.state.memories.count == count)
}

@Test @MainActor func noteReviewReportAppliesASilentRevisionAndPreservesHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var note = ReadingNote(
        paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Reader original.")
    reader.state.readingNotes = [note]
    let report = NoteReviewReport(
        revisions: [
            .init(
                noteID: note.id, modifiedAt: note.modifiedAt,
                markdown: "Reader original. Cross-paper relation noted.")
        ])
    let changed = try await reader.applyNoteReview(report)
    #expect(changed == 1)
    note = try #require(reader.state.readingNotes.first)
    #expect(note.markdown.contains("Cross-paper relation"))
    #expect(note.revisions?.first?.markdown == "Reader original.")
    #expect(try await LibraryStore(directory: root).load().readingNotes.first?.markdown == note.markdown)
}

@MainActor @Test func noteReviewOnlyAllowsSmallAppendOrLocalEdit() {
    let original = "匹配计算预算后，方法 A 的准确率更高。"
    #expect(ReaderModel.isSmallNoteRevision(from: original, to: original + " 该结论只在验证集上成立。"))
    #expect(ReaderModel.isSmallNoteRevision(from: original, to: "匹配计算预算后，方法 A 的准确率更高（验证集）。"))
    #expect(!ReaderModel.isSmallNoteRevision(from: original, to: "这是一段完全重写的笔记，讨论另一组实验、另一个数据集和完全不同的结论。"))
}
