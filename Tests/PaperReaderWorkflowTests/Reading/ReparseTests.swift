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
    model.state.papers[0].htmlReading = nil
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

@Test @MainActor func reparsePreservesCachedTranslationsBeyondAnUntranslatedGap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    await model.addDemo()
    var original = try #require(model.paper)
    #expect(original.blocks.count > 2)
    let first = original.blocks[0]
    let last = original.blocks.last!
    original.translations = [first.id.uuidString: "已存首段", last.id.uuidString: "已存末段"]
    original.htmlReading = try await HTMLReadingStore().append(
        [BilingualBlock(block: first, translation: "已存首段")], to: nil, paper: original, root: root)
    original.translatedBlockCount = 1
    #expect(await model.save(publishingReflow: original))
    await model.reparseCurrentPaper(replacingUnannotatedHTML: true)
    let updated = try #require(model.paper)
    #expect(updated.translations[last.id.uuidString] == "已存末段")
    #expect(updated.blocks.last?.id == last.id)
    #expect(updated.htmlReading?.sections.count == updated.blocks.count)
    #expect(updated.translatedBlockCount == 1)
    #expect(updated.originalPath == original.originalPath)
    let persisted = try await LibraryStore(directory: root).load()
    #expect(persisted.papers[0].translations[last.id.uuidString] == "已存末段")
}

@Test @MainActor func repeatedHeadingsReuseTheirOriginalIDsInReadingOrder() {
    let old = [
        TextBlock(sourcePage: -1, text: "Setting"), TextBlock(sourcePage: -1, text: "Body"),
        TextBlock(sourcePage: -1, text: "Setting"),
    ]
    let new = [
        TextBlock(sourcePage: -1, text: "Setting"), TextBlock(sourcePage: -1, text: "New caption"),
        TextBlock(sourcePage: -1, text: "Body"), TextBlock(sourcePage: -1, text: "Setting"),
    ]
    #expect(ReaderModel.previousBlock(at: 0, in: new, previous: old)?.id == old[0].id)
    #expect(ReaderModel.previousBlock(at: 3, in: new, previous: old)?.id == old[2].id)
    #expect(ReaderModel.previousBlock(at: 1, in: new, previous: old) == nil)
}
