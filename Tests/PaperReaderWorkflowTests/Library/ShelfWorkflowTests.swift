import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

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
