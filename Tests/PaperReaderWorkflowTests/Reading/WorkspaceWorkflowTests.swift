import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test @MainActor func readingWorkspaceRestoresStablePositionAcrossRestart() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    #expect(model.workspace(for: paper.id).status == .finished)
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

@Test(arguments: ["original", "reflow", "translated"])
@MainActor func reachingFinalSourcePagePersistsCompletionAcrossRestartAndReview(mode: String) async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.state.workspace[paper.id.uuidString] = PaperWorkspace(
        status: .reading, position: ReaderPosition(mode: "original", pageKey: "original-0", pageIndex: 0))
    model.select(paper.id)
    #expect(model.workspace(for: paper.id).status == .reading)
    model.changeMode(to: mode)
    model.navigateToSourcePage(2, blockID: nil, preferredMode: mode)
    #expect(model.mode == mode)
    #expect(model.workspace(for: paper.id).status == .finished)
    model.select(nil)
    await model.flushReadingPosition()

    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(reopened.workspace(for: paper.id).status == .finished)
    #expect(LibraryQuery.papers(in: reopened.state, collection: .reading).isEmpty)
    #expect(LibraryQuery.papers(in: reopened.state, collection: .finished).map(\.id) == [paper.id])
    reopened.select(paper.id)
    reopened.navigateToSourcePage(0)
    #expect(reopened.workspace(for: paper.id).status == .finished)
    #expect(PaperPageLocator.sourcePage(for: try #require(reopened.workspace(for: paper.id).position), in: paper) == 0)
    reopened.select(nil)
    await reopened.flushReadingPosition()
    let stored = try await LibraryStore(directory: root).load()
    #expect(stored.workspace[paper.id.uuidString]?.status == .finished)
}

@Test @MainActor func explicitlyUnreadAtFinalPageSurvivesRestartAndResumesAfterChangingPage() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    model.select(paper.id)
    let lastPosition = try #require(model.workspace(for: paper.id).position)
    model.setReadingStatus(.unread, for: paper.id)
    model.recordVisiblePage(model.visiblePage)
    model.select(nil)
    await model.flushReadingPosition()

    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(reopened.workspace(for: paper.id).status == .unread)
    #expect(reopened.workspace(for: paper.id).position == lastPosition)
    #expect(LibraryQuery.papers(in: reopened.state, collection: .finished).isEmpty)
    reopened.select(paper.id)
    reopened.recordVisiblePage(reopened.visiblePage)
    await reopened.flushReadingPosition()
    #expect(reopened.workspace(for: paper.id).status == .unread)
    #expect(reopened.workspace(for: paper.id).position == lastPosition)
    reopened.changeMode(to: "original")
    #expect(reopened.workspace(for: paper.id).status == .unread)
    reopened.navigateToPage(0)
    #expect(reopened.workspace(for: paper.id).status == .reading)
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: reopened.workspace(for: paper.id)) == .reading(percent: 33))
    reopened.navigateToPage(2)
    #expect(reopened.workspace(for: paper.id).status == .finished)
    reopened.select(nil)
    await reopened.flushReadingPosition()
}

@Test(arguments: ["original", "reflow", "translated"])
@MainActor func legacyFinalPositionMatchesCollectionsBeforeOpeningAndPersistsWhenOpened(mode: String) async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paper = workspacePaper()
    let position = try #require(PaperPageLocator.position(sourcePage: 2, mode: mode, in: paper))
    var state = LibraryState()
    state.papers = [paper]
    state.workspace[paper.id.uuidString] = PaperWorkspace(isFavorite: true, status: .reading, position: position)
    try await LibraryStore(directory: root).save(state)
    let model = try ReaderModel(root: root)
    await model.load()
    #expect(model.selectedPaperID == nil)
    #expect(LibraryQuery.papers(in: model.state, collection: .reading).isEmpty)
    #expect(LibraryQuery.papers(in: model.state, collection: .finished).map(\.id) == [paper.id])
    #expect(LibraryQuery.papers(in: model.state, collection: .favorites).map(\.id) == [paper.id])
    #expect(LibraryCollection.finished.includes(model.workspace(for: paper.id), for: paper))
    model.select(paper.id)
    #expect(model.workspace(for: paper.id).status == .finished)
    #expect(model.workspace(for: paper.id).position == position)
    model.select(nil)
    await model.flushReadingPosition()
    let stored = try await LibraryStore(directory: root).load()
    #expect(stored.workspace[paper.id.uuidString]?.status == .finished)
    #expect(stored.version == state.version)
}

@Test @MainActor func settingReadingAtFinalPageRetainsCompletionAndPosition() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    model.state.papers = [paper]
    let lastPosition = try #require(PaperPageLocator.position(sourcePage: 2, mode: "translated", in: paper))
    model.state.workspace[paper.id.uuidString] = PaperWorkspace(status: .reading, position: lastPosition)
    model.setReadingStatus(.reading, for: paper.id)
    #expect(model.workspace(for: paper.id).status == .finished)
    #expect(model.workspace(for: paper.id).position == lastPosition)
    model.setReadingStatus(.unread, for: paper.id)
    #expect(model.workspace(for: paper.id).status == .unread)
    #expect(model.workspace(for: paper.id).position == lastPosition)
    model.setReadingStatus(.reading, for: paper.id)
    #expect(model.workspace(for: paper.id).status == .finished)
    #expect(model.workspace(for: paper.id).position == lastPosition)
    await model.flushReadingPosition()
}

@Test(arguments: ["reselect", "evidence", "duplicate"])
@MainActor func reopeningCurrentPaperKeepsItsLoadedNavigation(action: String) async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    await model.addDemo()
    // A previously saved source block exercises citation navigation independently of import.
    model.state.papers[0].blocks = [TextBlock(sourcePage: 1, text: "Original fixture evidence.")]
    let paper = try #require(model.paper)
    await model.loadNavigation()
    let items = model.navigationItems
    #expect(!items.isEmpty)
    switch action {
    case "reselect":
        model.select(paper.id)
    case "evidence":
        let block = try #require(paper.blocks.last)
        model.jump(
            to: Evidence(
                id: "current-paper", title: paper.title, text: block.text, paperID: paper.id,
                blockID: block.id, sourcePage: block.sourcePage))
    default:
        let imported = await model.importURLs([root.appendingPathComponent(paper.originalPath)])
        #expect(imported == [paper.id])
    }
    #expect(model.selectedPaperID == paper.id)
    #expect(model.selectedSection == "library")
    #expect(model.navigationItems == items)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func sourceOutlineFollowsPublishedSectionAnchorsAndReadingEdition() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    var paper = workspacePaper()
    let tags = ["h1", "h2", "p", "h3", "h4", "h2"]
    let blocks = tags.enumerated().map { index, tag in
        var block = TextBlock(sourcePage: -1, text: "Passage \(index)")
        block.richContent = RichContent(
            html: "<span id='anchor-\(index)'></span><\(tag)>\(block.text)</\(tag)>",
            translationInput: block.text, mathematics: [:], mathDescriptions: [:])
        return block
    }
    let pairs = blocks.map { BilingualBlock(block: $0, translation: "已译") }
    let store = HTMLReadingStore()
    let first = try await store.append(Array(pairs.prefix(4)), to: nil, paper: paper, root: root)
    paper.blocks = blocks
    paper.htmlReading = first
    model.state.papers = [paper]
    model.select(paper.id)
    await model.loadNavigation()
    let initialItems = model.displayedNavigationItems
    #expect(initialItems.map(\.readingSectionID) == [blocks[1].id, blocks[3].id])
    let next = try await store.append(Array(pairs.suffix(2)), to: first, paper: paper, root: root)
    model.state.papers[0].htmlReading = next
    #expect(model.displayedNavigationItems.isEmpty)
    await model.loadNavigation()
    let items = model.displayedNavigationItems
    #expect(items.prefix(2).map(\.id) == initialItems.map(\.id))
    #expect(items.map(\.depth) == [0, 1, 0])
    let subsection = try #require(items.first { $0.depth == 1 })
    #expect(subsection.sourcePage == -1)
    #expect(model.navigationIndex(for: subsection) == 3)
    model.navigate(to: subsection)
    #expect(model.mode == "translated" && model.visiblePage == 3 && model.jumpPage == 3)
    model.changeMode(to: "original")
    #expect(model.displayedNavigationItems.isEmpty)
    model.navigate(to: subsection)
    #expect(model.mode == "original" && model.visiblePage == 0)
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func reselectingCurrentPaperPreservesPendingNavigationRequest() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = workspacePaper()
    let other = workspacePaper()
    model.state.papers = [paper, other]
    model.select(paper.id)
    let request = UUID()
    model.navigationRequestID = request
    model.navigationLoading = true
    model.selectedSection = "calendar"
    model.select(paper.id)
    #expect(model.navigationRequestID == request)
    #expect(model.navigationLoading)
    #expect(model.selectedSection == "library")
    model.select(other.id)
    #expect(model.navigationRequestID == nil)
    #expect(!model.navigationLoading)
    #expect(model.navigationItems.isEmpty)
    model.select(nil)
    await model.flushReadingPosition()
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
    model.state.workspace[paper.id.uuidString] = PaperWorkspace(
        status: .reading, position: ReaderPosition(mode: "original", pageKey: "original-0", pageIndex: 0))
    model.select(paper.id)
    model.changeMode(to: "original")
    model.navigateToPage(0)
    await model.flushReadingPosition()
    model.recordVisiblePage(1)
    model.recordVisiblePage(2)
    let store = try LibraryStore(directory: root)
    let beforeDebounce = try await store.load()
    #expect(beforeDebounce.workspace[paper.id.uuidString]?.position?.pageIndex == 0)
    #expect(beforeDebounce.workspace[paper.id.uuidString]?.status == .reading)
    // Concurrent WebKit fixtures can delay the main actor beyond the debounce timer.
    // Verify eventual persistence without manually flushing the operation under test.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var afterDebounce = try await store.load()
    while afterDebounce.workspace[paper.id.uuidString]?.position?.pageIndex != 2 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
        afterDebounce = try await store.load()
    }
    #expect(afterDebounce.workspace[paper.id.uuidString]?.position?.pageIndex == 2)
    #expect(afterDebounce.workspace[paper.id.uuidString]?.status == .finished)
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

@Test(arguments: [
    ("精确定位", "精确定位译文续页，不能跳到只有英文的首页。", "精确定位"),
    ("Transformer", "中文解释说明 Transformer 如何使用注意力连接输入与输出。", "中文解释"),
])
@MainActor func translatedSearchFindsTheActualContinuationPageWithoutChangingArtifacts(
    query: String, translation: String, translationMarker: String
) async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = try renderedSplitSearchPaper(root: root, translation: translation)
    let pages = paper.translatedPages
    #expect(pages.count > 1)
    let bytes = try pages.map { try Data(contentsOf: root.appendingPathComponent($0.relativePath)) }
    let first = try #require(PDFDocument(url: root.appendingPathComponent(pages[0].relativePath)))
    #expect(first.string?.contains(translationMarker) == false)
    let expected = try #require(
        pages.firstIndex { page in
            PDFDocument(url: root.appendingPathComponent(page.relativePath))?.string?.contains(translationMarker)
                == true
        })
    #expect(expected > 0)
    model.state.papers = [paper]
    model.select(paper.id)
    let result = try #require(model.searchInPaper(query).first { $0.isTranslation })
    model.navigate(to: result)
    await model.searchNavigationTask?.value
    #expect(model.visiblePage == expected)
    #expect(model.workspace(for: paper.id).position?.pageKey == pages[expected].id.uuidString)
    for (index, page) in pages.enumerated() {
        #expect(try Data(contentsOf: root.appendingPathComponent(page.relativePath)) == bytes[index])
    }
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func ambiguousTranslationContextFallsBackToOriginalInsteadOfClaimingATranslationPage() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = try renderedSplitSearchPaper(root: root, translation: "Transformer")
    model.state.papers = [paper]
    model.select(paper.id)
    model.navigate(to: try #require(model.searchInPaper("Transformer").first { $0.isTranslation }))
    await model.searchNavigationTask?.value
    #expect(model.mode == "original")
    #expect(model.visiblePage == 0)
    #expect(model.status.contains("无法区分"))
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func missingSearchArtifactFallsBackToOriginalWithAnExplanation() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let paper = splitSearchPaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.navigate(to: try #require(model.searchInPaper("注意力").first))
    await model.searchNavigationTask?.value
    #expect(model.mode == "original")
    #expect(model.visiblePage == 2)
    #expect(model.status.contains("无法读取"))
    #expect(model.status.contains("原文第 3 页"))
    model.select(nil)
    await model.flushReadingPosition()
}

@Test @MainActor func unmatchedSearchTextFallsBackToOriginalWithAnExplanation() async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let locator = ControlledPageTextLocator()
    let model = try ReaderModel(root: root, pageTextLocator: locator)
    await model.load()
    let paper = splitSearchPaper()
    model.state.papers = [paper]
    model.select(paper.id)
    model.navigate(to: try #require(model.searchInPaper("注意力").first))
    let task = model.searchNavigationTask
    await locator.waitUntilRequested()
    await locator.complete(with: nil)
    await task?.value
    #expect(model.mode == "original")
    #expect(model.visiblePage == 2)
    #expect(model.status.contains("未能在固定页中定位匹配文字"))
    model.select(nil)
    await model.flushReadingPosition()
}

@Test(arguments: ["page", "mode", "paper", "library", "background"])
@MainActor func delayedSearchNavigationCannotOverwriteANewerReaderAction(action: String) async throws {
    let root = workspaceDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let locator = ControlledPageTextLocator()
    let model = try ReaderModel(root: root, pageTextLocator: locator)
    await model.load()
    let paper = splitSearchPaper()
    let other = workspacePaper()
    model.state.papers = [paper, other]
    model.select(paper.id)
    model.navigate(to: try #require(model.searchInPaper("注意力").first))
    let task = model.searchNavigationTask
    await locator.waitUntilRequested()
    switch action {
    case "page": model.recordVisiblePage(1)
    case "mode": model.changeMode(to: "original")
    case "paper": model.select(other.id)
    case "library": model.select(nil)
    default: model.setActive(false)
    }
    let expectedPaper = model.selectedPaperID
    let expectedMode = model.mode
    let expectedPage = model.visiblePage
    let matchedPage = action == "page" ? paper.translatedPages[0] : paper.translatedPages[1]
    // This test service deliberately completes after cancellation to exercise the request identity guard.
    await locator.complete(with: matchedPage.id.uuidString)
    await task?.value
    #expect(model.selectedPaperID == expectedPaper)
    #expect(model.mode == expectedMode)
    #expect(model.visiblePage == expectedPage)
    model.select(nil)
    await model.flushReadingPosition()
}

private actor ControlledPageTextLocator: FixedPageTextLocating {
    private var continuation: CheckedContinuation<String?, Never>?
    private var requestObserver: CheckedContinuation<Void, Never>?
    private var requested = false

    func pageKey(matching matchedText: String, in pages: [PageArtifact], root: URL) async throws -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested = true
            requestObserver?.resume()
            requestObserver = nil
        }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestObserver = $0 }
    }

    func complete(with pageKey: String?) {
        continuation?.resume(returning: pageKey)
        continuation = nil
    }
}

private func splitSearchPaper() -> Paper {
    var paper = workspacePaper()
    paper.translatedPages.append(
        PageArtifact(blockIDs: paper.translatedPages[0].blockIDs, sourcePage: 2, relativePath: "continuation.pdf"))
    return paper
}

@MainActor private func renderedSplitSearchPaper(root: URL, translation: String) throws -> Paper {
    let block = TextBlock(
        sourcePage: 0,
        text: "Transformer appears in the original English paragraph. "
            + String(
                repeating: "The long original paragraph stays on immutable pages while its translation follows. ",
                count: 130))
    let pages = try [block.text.prefix(100).description, translation].enumerated().map { index, text in
        let path = "legacy-\(index).pdf"
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(root.appendingPathComponent(path) as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "PingFangSC-Regular" as CFString, 12, nil)
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        CTFrameDraw(
            CTFramesetterCreateFrame(
                framesetter, CFRange(), CGPath(rect: bounds.insetBy(dx: 50, dy: 50), transform: nil), nil), context)
        context.endPDFPage()
        context.closePDF()
        return PageArtifact(blockIDs: [block.id], sourcePage: 0, relativePath: path)
    }
    var paper = Paper(
        title: "Long local fixture", digest: "long", originalPath: "original.pdf", pageCount: 1, blocks: [block],
        warnings: [], canReflow: true)
    paper.translatedPages = pages
    paper.translations[block.id.uuidString] = translation
    paper.translatedBlockCount = 1
    return paper
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
