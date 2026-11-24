import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test func revealingASearchResultResolvesItsCurrentShelfAndIgnoresDeletedPapers() throws {
    let paper = Paper(
        title: "Shared title", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    let first = try Shelf(name: "First")
    let second = try Shelf(name: "Second")
    var state = LibraryState()
    state.papers = [paper]
    try state.apply(.create(first))
    try state.apply(.create(second))
    try state.apply(.move(paperID: paper.id, shelfID: first.id))
    let candidate = try #require(LibraryQuery.searchCandidates(in: state, query: "shared").first)

    try state.apply(.move(paperID: candidate.id, shelfID: second.id))
    let moved = try #require(ShelfSearchReveal(paperID: candidate.id, in: state))
    #expect(moved.paperID == candidate.id && moved.shelfID == second.id)
    let repeated = try #require(ShelfSearchReveal(paperID: candidate.id, in: state))
    #expect(repeated.id != moved.id)

    try state.apply(.delete(second.id))
    let unfiled = try #require(ShelfSearchReveal(paperID: candidate.id, in: state))
    #expect(unfiled.paperID == candidate.id && unfiled.shelfID == nil)
    try state.removePaper(candidate.id)
    #expect(ShelfSearchReveal(paperID: candidate.id, in: state) == nil)
}

@MainActor @Test func shelfChangesCommitBeforePublicationAndFailurePreservesState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let shelfID = try #require(await model.createShelf(name: "Topic"))
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let ids = await model.importURLs([pdf], selectAfterImport: false, shelfID: shelfID)
    let paperID = try #require(ids.first)
    #expect(model.state.shelfID(for: paperID) == shelfID)
    let originalPath = try #require(model.state.papers.first?.originalPath)
    #expect(await model.deleteShelf(shelfID))
    #expect(model.state.shelfID(for: paperID) == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(originalPath).path))
    let restarted = try ReaderModel(root: root)
    await restarted.load()
    #expect(restarted.state.papers.count == 1)
    #expect(restarted.state.shelves.isEmpty)
    // An unavailable SQLite destination must not publish a successful shelf edit.
    let savedRoot = root.appendingPathExtension("saved")
    try FileManager.default.moveItem(at: root, to: savedRoot)
    defer { try? FileManager.default.moveItem(at: savedRoot, to: root) }
    #expect(await model.createShelf(name: "Not saved") == nil)
    #expect(model.state.shelves.isEmpty)
    #expect(model.message?.contains("保存失败") == true)
}

@MainActor @Test func shelfDragProviderUsesOnlyItsDedicatedTypeAndMovesKnownPapers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let paperID = try #require(await model.importURLs([pdf], selectAfterImport: false).first)
    let shelfID = try #require(await model.createShelf(name: "Target"))
    let provider = PaperShelfDrag.provider(paperID)
    #expect(provider.registeredTypeIdentifiers == [PaperShelfDrag.typeIdentifier])
    let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
        provider.loadDataRepresentation(forTypeIdentifier: PaperShelfDrag.typeIdentifier) { data, error in
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: error ?? ReaderError.message("Missing test data"))
            }
        }
    }
    #expect(PaperShelfDrag.paperID(from: data) == paperID)
    #expect(PaperShelfDrag.paperID(from: Data("invalid".utf8)) == nil)
    #expect(PaperShelfDrag.receive([provider], model: model, shelfID: shelfID))
    for _ in 0..<500 where model.state.shelfID(for: paperID) != shelfID {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.state.shelfID(for: paperID) == shelfID)
    #expect(!PaperShelfDrag.receive([NSItemProvider(object: "Unrelated text" as NSString)], model: model, shelfID: nil))
}
