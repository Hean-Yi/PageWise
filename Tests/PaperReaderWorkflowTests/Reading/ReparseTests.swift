import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func retryOldImportPreservesOriginalIdentityNotesAndBookmarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    await model.addDemo()
    let original = try #require(model.paper)
    let bytes = try Data(contentsOf: root.appendingPathComponent(original.originalPath))
    model.state.papers[0].canReflow = false
    model.state.papers[0].warnings = ["old parser failure"]
    model.state.papers[0].summary = "Keep user notes"
    model.toggleBookmark()
    let bookmarks = model.state.bookmarks
    await model.reparseCurrentPaper()
    #expect(model.paper?.id == original.id)
    #expect(model.paper?.canReflow == true)
    #expect(model.paper?.summary == "Keep user notes")
    #expect(model.state.bookmarks == bookmarks)
    #expect(model.paper?.blocks.map(\.id) == original.blocks.map(\.id))
    #expect(try Data(contentsOf: root.appendingPathComponent(original.originalPath)) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Papers").path).count == 1)
    let saved = try await LibraryStore(directory: root).load()
    #expect(saved.papers[0].canReflow)
    #expect(saved.papers[0].summary == "Keep user notes")
    let block = original.blocks[0]
    model.state.papers[0].translatedPages = [
        PageArtifact(blockIDs: [block.id], sourcePage: 0, relativePath: "published.pdf")
    ]
    let published = model.state.papers[0]
    await model.reparseCurrentPaper()
    #expect(model.paper?.blocks == published.blocks)
    #expect(model.paper?.translatedPages == published.translatedPages)
}
