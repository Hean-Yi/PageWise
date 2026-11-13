import Foundation
import Testing

@testable import PaperReaderKit

@Test func notesPreserveUserTextAndDetectEdits() throws {
    let id = UUID()
    let first = try NoteMerger.merge(
        existing: "# My notes\n\nMy own ideas.\n", body: "Summary one", paperID: id, baseline: nil)
    let second = try NoteMerger.merge(existing: first.text, body: "Summary two", paperID: id, baseline: first.baseline)
    #expect(second.text.contains("My own ideas."))
    #expect(!second.text.contains("Summary one"))
    #expect(second.text.components(separatedBy: "Summary two").count == 2)
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(
            existing: first.text.replacingOccurrences(of: "Summary one", with: "Edited by me"), body: "New",
            paperID: id, baseline: first.baseline)
    }
}

@Test func librarySurvivesRestart() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try LibraryStore(directory: dir)
    var state = LibraryState()
    state.memories = [MemoryItem(text: "Research direction", sourceID: UUID())]
    try await store.save(state)
    let reopened = try LibraryStore(directory: dir)
    let loaded = try await reopened.load()
    #expect(loaded.memories.first?.text == "Research direction")
}

@Test func currentPaperEvidenceComesFirst() {
    let current = Paper(
        title: "Current", digest: "a", originalPath: "a.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Attention query and key explanation")], warnings: [], canReflow: true)
    let other = Paper(
        title: "Other", digest: "b", originalPath: "b.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Attention attention attention")], warnings: [], canReflow: true)
    let hits = Retriever.context(
        question: "attention", selection: "query", current: current, others: [other], notes: [])
    #expect(hits.first?.paperID == current.id)
    #expect(Set(hits.map(\.id)).count == hits.count)
}

@Test func readingCountsUnionAndClipsToDay() {
    let id = UUID()
    let start = Date(timeIntervalSince1970: 10000)
    let entries = [
        ReadingEntry(paperID: id, start: start.addingTimeInterval(-30), end: start.addingTimeInterval(60)),
        ReadingEntry(paperID: id, start: start.addingTimeInterval(30), end: start.addingTimeInterval(120)),
        ReadingEntry(paperID: id, start: start.addingTimeInterval(200), end: start.addingTimeInterval(300)),
    ]
    #expect(ReadingMetrics.seconds(entries, during: DateInterval(start: start, duration: 250)) == 170)
}

@Test func missingMarkersCannotOverwriteManagedNote() {
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(existing: "User removed the block", body: "new", paperID: UUID(), baseline: "previous")
    }
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
        question: "attention", selection: "CRITICAL_SELECTED_EVIDENCE", current: paper, others: [], notes: [])
    #expect(context.first?.blockID == chosen.id)
}

@Test func translatedSelectionUsesSourceAnchor() {
    let early = TextBlock(sourcePage: 0, text: String(repeating: "attention ", count: 4000))
    let selected = TextBlock(sourcePage: 20, text: "The final ablation measures generalization.")
    let paper = Paper(
        title: "Long", digest: "long", originalPath: "long.pdf", pageCount: 21, blocks: [early, selected], warnings: [],
        canReflow: true)
    let hits = Retriever.context(
        question: "解释", selection: "最后的消融实验", current: paper, others: [], notes: [], selectedBlockIDs: [selected.id])
    #expect(hits.first?.blockID == selected.id)
}

@Test func noteRecoveryChecksFileAndPreservesDiscussion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = VaultService(root: root)
    try await service.select(folder)
    var paper = Paper(
        title: "Paper", digest: "x", originalPath: "x.pdf", pageCount: 1, blocks: [], warnings: [], canReflow: false)
    paper.savedDiscussion = "A previously saved discussion"
    let saved = try await service.save(paper: paper, body: "Generated summary")
    // Simulate an app/database failure after the external file write: the original paper still has no binding.
    let recovered = try await service.recover(paper)
    #expect(recovered.noteBaseline == saved.baseline)
    #expect(recovered.savedDiscussion == paper.savedDiscussion)
    let file = folder.appendingPathComponent(saved.path)
    let existing = try String(contentsOf: file, encoding: .utf8)
    try Data((existing + "\nMy own idea\n").utf8).write(to: file, options: .atomic)
    _ = try await service.save(paper: recovered, body: "Updated summary")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("My own idea"))
    let generated = try String(contentsOf: file, encoding: .utf8)
    try Data(generated.replacingOccurrences(of: "Updated summary", with: "User-edited summary").utf8).write(
        to: file, options: .atomic)
    let stale = try await service.recover(paper)
    #expect(stale.noteBaseline == nil)
    await #expect(throws: (any Error).self) { try await service.save(paper: stale, body: "Should not overwrite") }
}
