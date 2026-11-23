import Foundation
import PaperReaderKit
import Testing
import WebKit

@testable import PaperReaderUI

@Test(arguments: [false, true]) @MainActor
func htmlMarksFollowTheirEditionThroughRebuildAndErase(reusesFirstBlock: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let intro = TextBlock(sourcePage: 0, text: "Old opening.")
    let shared = TextBlock(sourcePage: 0, text: "Shared observation, followed by detail.")
    var paper = Paper(
        title: "Editions", digest: "version-fixture", originalPath: "source.pdf",
        pageCount: 1, blocks: [intro, shared], warnings: [], canReflow: true)
    let store = HTMLReadingStore()
    func artifact(_ paper: Paper, label: String) async throws -> HTMLReadingArtifact {
        try await store.append(
            paper.blocks.map { BilingualBlock(block: $0, translation: label) },
            to: nil, paper: paper, root: root)
    }
    paper.htmlReading = try await artifact(paper, label: "旧版译文")
    paper.translatedBlockCount = 2
    try #require(await reader.save(adding: paper))
    reader.select(paper.id)
    reader.openRetainedReading(nil)
    let oldStamp = try #require(reader.htmlAnnotationVersion)
    let quote = "Shared observation"
    let selected = HTMLTextSelection(pageKey: shared.id.uuidString, text: quote, start: 0, end: quote.utf16.count)
    reader.captureHTMLSelection([selected])
    reader.highlightSelection()
    let oldMark = try #require(reader.displayedHTMLHighlights.first)
    #expect(oldMark.contentVersion == oldStamp)
    let oldScope = try reader.discussionNoteScope(for: paper.id)
    let evidence = Evidence(id: "S1", title: paper.title, text: shared.text, paperID: paper.id, blockID: shared.id)
    let archived = RetainedReading(paper: paper)
    paper.retainedReadings = [archived]
    if !reusesFirstBlock { paper.blocks[0] = TextBlock(sourcePage: 0, text: "Different opening.") }
    paper.htmlReading = try await artifact(paper, label: "新版译文")
    try #require(await reader.save(publishingReflow: paper))
    let newStamp = try #require(reader.htmlAnnotationVersion)
    #expect(newStamp != oldStamp)
    #expect(reader.displayedHTMLHighlights.isEmpty)
    await #expect(throws: ReaderError.self) {
        try await reader.saveDiscussionNote(
            in: oldScope, sources: [(evidence, quote)], markdown: "过期", requestID: UUID())
    }
    let note = try await reader.saveDiscussionNote(
        in: reader.discussionNoteScope(for: paper.id), sources: [(evidence, quote)],
        markdown: "新观点", requestID: UUID())
    let newMark = try #require(reader.displayedHTMLHighlights.first)
    #expect(note.contentVersion == newStamp && newMark.contentVersion == newStamp && newMark.id != oldMark.id)

    let coordinator = HTMLCoordinator(model: reader)
    let web = coordinator.makeView()
    defer { coordinator.stop(web) }
    web.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    func shows(_ label: String, ink: Bool) async -> Bool {
        coordinator.update(web)
        for _ in 0..<180 {
            if (try? await web.callAsyncJavaScript(
                "return document.querySelector('.translation')?.textContent===label && !!CSS.highlights?.get('saved')?.size===ink",
                arguments: ["label": label, "ink": ink], in: nil, contentWorld: .defaultClient) as? Bool) == true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
    #expect(await shows("新版译文", ink: true))
    reader.navigate(to: oldMark)
    #expect(reader.retainedReadingID == archived.id && reader.visiblePage == 1)
    #expect(reader.displayedHTMLHighlights == [oldMark])
    #expect(await shows("旧版译文", ink: true))
    reader.captureHTMLSelection([selected])
    reader.performHTMLAnnotation(["color": "yellow", "style": "highlight", "remove": true, "legacy": [[String: Any]]()])
    #expect(reader.displayedHTMLHighlights.isEmpty)
    #expect(await shows("旧版译文", ink: false))
    reader.navigate(to: newMark)
    #expect(reader.retainedReadingID == nil && reader.displayedHTMLHighlights == [newMark])
    #expect(await shows("新版译文", ink: true))

    // A pre-versioned library may already show the same highlight in both editions. Editing one keeps
    // a versioned copy in the other, even if the old serialized value contained no version property.
    var legacy = oldMark
    legacy.contentVersion = nil
    legacy.id = UUID()
    let encoded = try JSONEncoder().encode(legacy)
    #expect(try JSONDecoder().decode(Highlight.self, from: encoded).contentVersion == nil)
    reader.state.highlights = [legacy]
    reader.openRetainedReading(archived.id)
    reader.captureHTMLSelection([selected])
    reader.performHTMLAnnotation([
        "color": "purple", "style": "underline", "remove": false, "legacy": [[String: Any]](),
    ])
    #expect(reader.displayedHTMLHighlights.count == 1 && reader.displayedHTMLHighlights.first?.color == .purple)
    reader.openRetainedReading(nil)
    #expect(reader.displayedHTMLHighlights.count == 1 && reader.displayedHTMLHighlights.first?.color == legacy.color)
    #expect(reader.displayedHTMLHighlights.first?.contentVersion == newStamp)

    let stable = try #require(paper.htmlReading)
    let next = TextBlock(sourcePage: 0, text: "New detail.")
    let continuation = try await store.append(
        [BilingualBlock(block: next, translation: "追加。")], to: stable, paper: paper, root: root)
    #expect(continuation.readingNoteVersion(digest: paper.digest) == newStamp)
    await reader.highlightSaveTask?.value
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    #expect(Set(reopened.state.highlights.compactMap(\.contentVersion)) == [oldStamp, newStamp])
}
