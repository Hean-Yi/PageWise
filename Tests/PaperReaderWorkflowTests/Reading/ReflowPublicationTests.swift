import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func failedPublicationLeavesPendingSourceAndExistingPagesAvailable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let original = Paper(
        title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Published source.")], warnings: [], canReflow: true)
    model.state.papers = [original]
    model.select(original.id)
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
    let original = Paper(
        title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Published source.")], warnings: [], canReflow: true)
    model.state.papers = [original]
    model.select(original.id)
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

@Test @MainActor func readinessAndBlockPublicationPreserveLatestPrefixInEitherQueueOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let first = TextBlock(sourcePage: 0, text: "First source.")
    let second = TextBlock(sourcePage: 0, text: "Second source.")
    var paper = Paper(
        title: "Ready", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [first], warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: [first, second])
    paper.reflowJob?.evidenceRoute = "html"
    let jobID = try #require(paper.reflowJob?.id)
    model.state.papers = [paper]
    #expect(await model.save())
    var publication = paper
    publication.blocks.append(second)
    publication.reflowJob?.completedSourceIDs = [first.id, second.id]
    let stalePublication = publication
    async let publish = model.save(publishingReflow: stalePublication)
    async let present = model.save(presentingReflow: (paperID: paper.id, jobID: jobID))
    #expect(await publish)
    #expect(await present)
    // An in-flight publisher may have captured a false flag before presentation was queued.
    #expect(await model.save(publishingReflow: stalePublication))
    let saved = try await LibraryStore(directory: root).load().papers[0]
    #expect(saved.blocks == [first, second])
    #expect(saved.reflowJob?.completedSourceIDs == [first.id, second.id])
    #expect(saved.reflowJob?.hasPresentedContent == true)
    #expect(model.state.papers[0].reflowJob?.hasPresentedContent == true)
}
