import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func failedPublicationLeavesPendingSourceAndExistingPagesAvailable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    await model.addDemo()
    let original = try #require(model.paper)
    var publication = original
    publication.translatedBlockCount = 1
    publication.translatedPages = [
        PageArtifact(blockIDs: [original.blocks[0].id], sourcePage: 0, relativePath: "uncommitted.pdf")
    ]
    let database = root.appendingPathComponent("library.sqlite")
    try FileManager.default.removeItem(at: database)
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
    #expect(await model.save(publishingReflow: publication) == false)
    #expect(model.paper?.translatedPages.isEmpty == true)
    #expect(model.paper?.translatedBlockCount == 0)
    #expect(model.paper?.blocks == original.blocks)
}

@Test @MainActor func queuedPublicationAndWorkspaceSaveKeepCommittedPageReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    await model.addDemo()
    let original = try #require(model.paper)
    var publication = original
    publication.translatedBlockCount = 1
    publication.translatedPages = [
        PageArtifact(blockIDs: [original.blocks[0].id], sourcePage: 0, relativePath: "committed.pdf")
    ]
    let published = publication
    async let first = model.save(publishingReflow: published)
    async let second = model.save()
    #expect(await first)
    #expect(await second)
    let stored = try await LibraryStore(directory: root).load()
    #expect(stored.papers[0].translatedPages == published.translatedPages)
    #expect(stored.papers[0].translatedBlockCount == 1)
    #expect(model.paper?.translatedPages == published.translatedPages)
}
