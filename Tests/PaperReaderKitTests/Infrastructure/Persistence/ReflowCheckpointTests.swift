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
    #expect(upgraded.version == 8)
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
    try ReflowArtifactCleanup.removeUncommittedFiles(in: root, papers: [paper])
    #expect(try Data(contentsOf: root.appendingPathComponent(oldPath)) == oldBytes)
    let copy = try JSONDecoder().decode(Paper.self, from: JSONEncoder().encode(paper))
    let projected = try #require(copy.retainedReadings?.first).projecting(copy)
    #expect(projected.blocks == [block])
    #expect(projected.htmlReading?.relativePath == oldPath)
    #expect(copy.reflowJob?.sources.count == 1)
}
