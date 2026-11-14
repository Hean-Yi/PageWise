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

@Test func missingMarkersCannotOverwriteManagedNote() {
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(existing: "User removed the block", body: "new", paperID: UUID(), baseline: "previous")
    }
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
