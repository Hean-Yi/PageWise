import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func readingWorkspaceRestoresStablePositionAcrossRestart() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    #expect(model.workspace(for: paper.id).status == .reading)
    #expect(model.workspace(for: paper.id).lastOpenedAt != nil)
    model.toggleFavorite(paper.id)
    model.changeMode(to: "reflow")
    model.recordVisiblePage(1)
    model.setReadingStatus(.finished, for: paper.id)
    model.endReading()
    await model.flushReadingPosition()
    let saved = model.workspace(for: paper.id)

    let reopened = try ReaderModel(root: root)
    await reopened.load()
    reopened.state.papers[0].previewPages.insert(
        PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "new-leading-page.pdf"), at: 0)
    reopened.select(paper.id)
    #expect(reopened.mode == "reflow")
    #expect(reopened.visiblePage == 2)
    #expect(reopened.jumpPage == 2)
    #expect(reopened.workspace(for: paper.id).position?.pageKey == saved.position?.pageKey)
    #expect(reopened.workspace(for: paper.id).isFavorite)
    #expect(reopened.workspace(for: paper.id).status == .finished)
    #expect(try #require(reopened.workspace(for: paper.id).lastOpenedAt) >= #require(saved.lastOpenedAt))
    reopened.select(nil)
    await reopened.flushReadingPosition()
}

@Test @MainActor func bookmarksDeduplicateAndReturnToExactLayoutAcrossModes() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.changeMode(to: "reflow")
    model.navigateToPage(1)
    model.toggleBookmark()
    let bookmark = try #require(model.currentBookmarks.first)
    #expect(model.isCurrentPageBookmarked)
    model.changeMode(to: "original")
    #expect(model.visiblePage == 2)
    #expect(!model.isCurrentPageBookmarked)
    model.navigate(to: bookmark)
    #expect(model.mode == "reflow")
    #expect(model.visiblePage == 1)
    #expect(model.isCurrentPageBookmarked)
    model.state.bookmarks.append(bookmark)
    model.toggleBookmark()
    #expect(model.currentBookmarks.isEmpty)
    model.toggleBookmark()
    #expect(model.currentBookmarks.count == 1)
    let other = workspacePaper()
    model.state.papers.append(other)
    model.select(other.id)
    #expect(model.currentBookmarks.isEmpty)
    model.navigate(to: try #require(model.state.bookmarks.first))
    #expect(model.selectedPaperID == paper.id)
    #expect(model.visiblePage == 1)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func navigationMapsSourcePagesAndKeepsUnpublishedTranslationOut() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.changeMode(to: "original")
    model.navigateToPage(2)
    model.changeMode(to: "translated")
    #expect(model.mode == "translated")
    #expect(model.visiblePage == 0)
    model.navigateToSourcePage(0)
    #expect(model.mode == "original")
    #expect(model.visiblePage == 0)
    #expect(model.status.contains("原文"))
    let match = try #require(model.searchInPaper("注意力").first)
    model.navigate(to: match)
    #expect(model.visiblePage == 0)
    #expect(model.mode == "translated")
    let highlight = Highlight(
        paperID: paper.id, pageKey: paper.previewPages[1].id.uuidString, pageIndex: 0,
        text: "Attention", rects: [[10, 20, 30, 40]])
    model.navigate(to: highlight)
    #expect(model.mode == "reflow")
    #expect(model.visiblePage == 1)
    let other = workspacePaper()
    model.state.papers.append(other)
    model.select(other.id)
    model.navigate(to: match)
    #expect(model.selectedPaperID == other.id)
    #expect(model.searchInPaper(" \n").isEmpty)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func scrollPositionDebouncesDiskWritesAndEventuallySavesLatestPage() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.changeMode(to: "original")
    model.navigateToPage(0)
    await model.flushReadingPosition()
    model.recordVisiblePage(1)
    model.recordVisiblePage(2)
    let store = try LibraryStore(directory: root)
    let beforeDebounce = try await store.load()
    #expect(beforeDebounce.workspace[paper.id.uuidString]?.position?.pageIndex == 0)
    try await Task.sleep(for: .milliseconds(700))
    let afterDebounce = try await store.load()
    #expect(afterDebounce.workspace[paper.id.uuidString]?.position?.pageIndex == 2)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func evidenceForUnpublishedBlockFallsBackToItsOriginalSourcePage() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    var paper = workspacePaper()
    let unpublished = TextBlock(sourcePage: 2, text: "Evidence not on the translated page.")
    paper.blocks.append(unpublished)
    model.state.papers = [paper]
    model.select(paper.id)
    #expect(model.mode == "translated")
    model.jump(
        to: Evidence(
            id: "unpublished", title: paper.title, text: unpublished.text, paperID: paper.id,
            blockID: unpublished.id, sourcePage: unpublished.sourcePage))
    #expect(model.mode == "original")
    #expect(model.visiblePage == 2)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func leavingPaperFlushesLatestVisiblePageWithoutWaitingForDebounce() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.changeMode(to: "original")
    model.recordVisiblePage(1)
    model.recordVisiblePage(2)
    model.setActive(false)
    await model.flushReadingPosition()
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    reopened.select(paper.id)
    #expect(reopened.mode == "original")
    #expect(reopened.visiblePage == 2)
    reopened.select(nil)
    await reopened.flushReadingPosition()
}

private func workspaceDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PaperReader-Workspace-" + UUID().uuidString)
}

private func workspacePaper() -> Paper {
    let blocks = [
        TextBlock(sourcePage: 0, text: "The first extracted paragraph."),
        TextBlock(sourcePage: 2, text: "Attention remains tied to its original source."),
    ]
    var paper = Paper(
        title: "Workspace fixture", digest: UUID().uuidString, originalPath: "fixture.pdf", pageCount: 3,
        blocks: blocks, warnings: [], canReflow: true)
    paper.previewPages = blocks.map {
        PageArtifact(blockIDs: [$0.id], sourcePage: $0.sourcePage, relativePath: "preview-\($0.sourcePage).pdf")
    }
    paper.translatedPages = [PageArtifact(blockIDs: [blocks[1].id], sourcePage: 2, relativePath: "translated.pdf")]
    paper.translations[blocks[1].id.uuidString] = "注意力保持原文定位。"
    paper.translatedBlockCount = 2
    return paper
}
