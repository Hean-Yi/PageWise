import Foundation
import Testing

@testable import PaperReaderKit

@Test func versionSevenMigrationPreservesOriginalReadingAndLeavesNewTaskAbsent() throws {
    let block = TextBlock(sourcePage: 0, text: "Preserved source")
    var paper = Paper(
        title: "Fixture", digest: "digest", originalPath: "original.pdf", pageCount: 1, blocks: [block], warnings: [],
        canReflow: true)
    paper.translations[block.id.uuidString] = "保留的译文"
    var library = LibraryState()
    library.papers = [paper]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
    json["version"] = 7
    let upgraded = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(upgraded.version == LibraryState.currentVersion)
    #expect(upgraded.papers[0].id == paper.id)
    #expect(upgraded.papers[0].blocks == paper.blocks)
    #expect(upgraded.papers[0].translations == paper.translations)
    #expect(upgraded.papers[0].reflowJob == nil)
}

@Test func retainedReadingSurvivesCleanupAndKeepsItsSourceVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let block = TextBlock(sourcePage: 0, text: "Original source before regeneration")
    var paper = Paper(
        title: "Fixture", digest: "digest", originalPath: "original.pdf", pageCount: 1, blocks: [block], warnings: [],
        canReflow: true)
    paper.htmlReading = try await HTMLReadingStore().append(
        [BilingualBlock(block: block, translation: "保留旧译文")], to: nil, paper: paper, root: root)
    let oldPath = try #require(paper.htmlReading?.relativePath)
    let oldBytes = try Data(contentsOf: root.appendingPathComponent(oldPath))
    let retained = RetainedReading(paper: paper)
    paper.retainedReadings = [retained]
    paper.htmlReading = nil
    paper.blocks = []
    paper.reflowJob = ReflowJob(sources: [TextBlock(sourcePage: 0, text: "New evidence")])
    try ReadingArtifactCleanup.removeUncommittedFiles(in: root, papers: [paper])
    #expect(try Data(contentsOf: root.appendingPathComponent(oldPath)) == oldBytes)
    let copy = try JSONDecoder().decode(Paper.self, from: JSONEncoder().encode(paper))
    let projected = try #require(copy.retainedReadings?.first).projecting(copy)
    #expect(projected.blocks == [block])
    #expect(projected.htmlReading?.relativePath == oldPath)
    #expect(copy.reflowJob?.sources.count == 1)
}

@Test(arguments: [nil, "pdf", "tex", "html"] as [String?], [false, true])
func versionEightMigrationReplansOnlyUnfinishedSourceJobs(route: String?, finished: Bool) throws {
    let sources = [
        TextBlock(sourcePage: -1, text: "Published source."), TextBlock(sourcePage: -1, text: "Pending source."),
    ]
    let plan = AIReflowPlan(
        version: 1, windowID: UUID(), evidenceDigest: "old-metadata-digest", requestConfigurationDigest: "fixture",
        blocks: sources.map {
            AIReflowPlan.Block(
                id: UUID(), kind: .paragraph,
                sourceSegments: [.init(sourceID: $0.id, startUTF16: 0, endUTF16: $0.text.utf16.count)], objectRefs: [])
        })
    var paper = Paper(
        title: "Existing", digest: "fixture", originalPath: "original.pdf", pageCount: 1, blocks: [sources[0]],
        warnings: [], canReflow: true)
    paper.htmlReading = HTMLReadingArtifact(
        relativePath: "published.html",
        sections: [
            PageArtifact(id: sources[0].id, blockIDs: [sources[0].id], sourcePage: -1, relativePath: "published.html")
        ], assets: [])
    paper.translations[sources[0].id.uuidString] = "已发布译文。"
    paper.reflowJob = ReflowJob(sources: sources)
    paper.reflowJob?.evidenceRoute = route
    paper.reflowJob?.acceptedPlan = plan
    paper.reflowJob?.committedBlockIDs = [plan.blocks[0].id]
    paper.reflowJob?.completedSourceIDs = [sources[0].id]
    paper.reflowJob?.finished = finished
    var state = LibraryState()
    state.version = 8
    state.papers = [paper]
    state.highlights = [
        Highlight(paperID: paper.id, pageKey: sources[0].id.uuidString, pageIndex: 0, text: sources[0].text, rects: [])
    ]
    let migrated = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
    let result = try #require(migrated.papers.first)
    let reset = !finished && (route == "tex" || route == "html")
    #expect(migrated.version == LibraryState.currentVersion)
    #expect(result.reflowJob?.acceptedPlan == (reset ? nil : plan))
    #expect(result.reflowJob?.committedBlockIDs == (reset ? [] : [plan.blocks[0].id]))
    #expect(result.reflowJob?.completedSourceIDs == [sources[0].id])
    #expect(result.reflowJob?.sources == sources)
    #expect(result.blocks == paper.blocks && result.htmlReading == paper.htmlReading)
    #expect(result.translations == paper.translations && migrated.highlights == state.highlights)
    let reopened = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(migrated))
    #expect(reopened.papers.first?.reflowJob == result.reflowJob)
}
