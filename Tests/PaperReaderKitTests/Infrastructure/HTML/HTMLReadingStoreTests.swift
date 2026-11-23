import Foundation
import SwiftSoup
import Testing

@testable import PaperReaderKit

@Test func htmlReadingAppendsStableSectionsDeduplicatesSVGAndCleansOnlyUnreferencedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let svg =
        "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><text x='10' y='50'>KEEP_LABEL</text></svg>"
    let uri = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    func block(_ text: String) -> TextBlock {
        var block = TextBlock(sourcePage: 0, text: text)
        block.richContent = RichContent(
            html: "<p>\(text) <math><mi>x</mi></math></p><img src='\(uri)' width='200' height='100'>",
            translationInput: text + " [[MATH_1]]", mathematics: ["[[MATH_1]]": "<math><mi>x</mi></math>"],
            mathDescriptions: ["[[MATH_1]]": "x"])
        return block
    }
    let first = block("First original")
    let second = block("Second original")
    var paper = Paper(
        title: "Local HTML", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [first, second], warnings: [], canReflow: true)
    let store = HTMLReadingStore()
    let initial = try await store.append(
        [BilingualBlock(block: first, translation: "第一段 [[MATH_1]]")], to: nil, paper: paper, root: root)
    paper.htmlReading = initial
    let initialURL = root.appendingPathComponent(initial.relativePath)
    let originalBytes = try Data(contentsOf: initialURL)
    let next = try await store.append(
        [BilingualBlock(block: second, translation: "第二段 [[MATH_1]]")], to: initial, paper: paper, root: root)
    #expect(next.assets == initial.assets)
    #expect(next.sections.map(\.id) == [first.id, second.id])
    #expect(try Data(contentsOf: initialURL) == originalBytes)
    let append = try await store.appendedContent(
        at: root.appendingPathComponent(next.relativePath), excluding: [first.id.uuidString])
    #expect(!append.contains("First original"))
    #expect(append.contains("Second original"))
    let finalHTML = try String(contentsOf: root.appendingPathComponent(next.relativePath), encoding: .utf8)
    // A freshly appended section and a reopened section must have identical text-node coordinates.
    func domText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        return node.getChildNodes().map(domText).joined()
    }
    let liveSection = try #require(try SwiftSoup.parseBodyFragment(append).select("section").first())
    let savedSection = try #require(try SwiftSoup.parse(finalHTML).getElementById("block-" + second.id.uuidString))
    #expect(domText(liveSection) == domText(savedSection))
    #expect(finalHTML.contains("<math>"))
    #expect(finalHTML.contains("第二段"))
    #expect(!finalHTML.contains("base64"))
    #expect(!finalHTML.contains("column-width"))
    #expect(try String(contentsOf: root.appendingPathComponent(next.assets[0]), encoding: .utf8) == svg)
    paper.htmlReading = next
    try HTMLReadingStore.cleanup(root: root, paper: paper)
    #expect(!FileManager.default.fileExists(atPath: initialURL.path))
    let folder = root.appendingPathComponent(next.relativePath).deletingLastPathComponent()
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    let reference = try #require(PaperPageLocator.resolve(pageKey: first.id.uuidString, in: paper))
    #expect(reference.pageIndex == 0)
    #expect(PaperPageLocator.sourcePage(for: reference, in: paper) == 0)
    await #expect(throws: (any Error).self) {
        try await store.append([BilingualBlock(block: first, translation: nil)], to: next, paper: paper, root: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
}

@Test func htmlReadingFailedBatchDoesNotReplacePublishedContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var paper = Paper(
        title: "Failure", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    let first = TextBlock(sourcePage: 0, text: "Saved evidence")
    let store = HTMLReadingStore()
    let artifact = try await store.append(
        [BilingualBlock(block: first, translation: nil)], to: nil, paper: paper, root: root)
    paper.htmlReading = artifact
    var missing = TextBlock(sourcePage: 0, text: "Missing image")
    missing.richContent = RichContent(
        html: "<img src='https://example.com/private.png'>", translationInput: "", mathematics: [:],
        mathDescriptions: [:])
    await #expect(throws: (any Error).self) {
        try await store.append(
            [BilingualBlock(block: missing, translation: nil)], to: artifact, paper: paper, root: root)
    }
    let abandoned = try await store.append(
        [BilingualBlock(block: TextBlock(sourcePage: 0, text: "Uncommitted"), translation: nil)], to: artifact,
        paper: paper, root: root)
    try HTMLReadingStore.cleanup(root: root, paper: paper)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(abandoned.relativePath).path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(artifact.relativePath).path))
    var state = LibraryState()
    state.papers = [paper]
    let roundtrip = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
    #expect(roundtrip.papers[0].htmlReading == artifact)
    state.papers[0].htmlReading = nil
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    object["version"] = 5
    let migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(migrated.version == LibraryState.currentVersion)
    #expect(migrated.papers[0].id == paper.id)
    #expect(migrated.papers[0].htmlReading == nil)
}
