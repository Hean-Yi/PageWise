import Foundation
import PaperReaderTestSupport
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@MainActor @Test(arguments: [false, true])
func paperSearchPrewarmsCommittedPDFPagesAcrossRestartAndForgetsDeletedPapers(downloaded: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let file = root.appendingPathComponent("fixture.pdf")
    try AttentionFixture.write(to: file)
    let candidate = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Search fixture", authors: "", year: "2025",
        source: .crossref)
    let ids = await reader.importURLs([file], selectAfterImport: false, metadata: downloaded ? candidate : nil)
    let id = try #require(ids.first)
    await reader.paperSearchWarmup.worker?.value
    #expect(await reader.paperSearchIndex.indexedPaperIDs == [id])
    let paper = try #require(reader.state.papers.first)
    #expect(paper.blocks.isEmpty)
    let cache = root.appendingPathComponent(paper.originalPath).deletingLastPathComponent()
        .appendingPathComponent("search-passages-v1.json")
    let modified = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    await reopened.paperSearchWarmup.worker?.value
    #expect(await reopened.paperSearchIndex.indexedPaperIDs == [id])
    let hit = try #require(
        try await reopened.paperSearchIndex.search("interpreted", papers: reopened.state.papers).first)
    #expect(hit.sourcePage == 1 && hit.blockID == nil && hit.excerpt.localizedStandardContains("interpreted"))
    #expect(try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    #expect(await reopened.deletePaper(id))
    #expect(await reopened.paperSearchIndex.indexedPaperIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
}
