import Foundation
import Testing

@testable import PaperReaderKit

@Test func readingProgressResolvesStablePageInsteadOfDisplayIndex() {
    var paper = progressPaper()
    let page = PageArtifact(blockIDs: [], sourcePage: 3, relativePath: "fixed.pdf")
    paper.previewPages = [page]
    let workspace = PaperWorkspace(
        status: .reading, position: ReaderPosition(mode: "reflow", pageKey: page.id.uuidString, pageIndex: 99))
    #expect(ReadingProgress.resolve(paper: paper, workspace: workspace) == .reading(percent: 40))
    paper.previewPages.append(PageArtifact(blockIDs: [], sourcePage: 8, relativePath: "later.pdf"))
    #expect(ReadingProgress.resolve(paper: paper, workspace: workspace) == .reading(percent: 40))
    paper.previewPages = []
    #expect(ReadingProgress.resolve(paper: paper, workspace: workspace) == .reading(percent: nil))
}

@Test func readingProgressTreatsTranslatedAndOriginalPagesConsistently() {
    var paper = progressPaper()
    let page = PageArtifact(blockIDs: [], sourcePage: 5, relativePath: "translation.pdf")
    paper.translatedPages = [page]
    for position in [
        ReaderPosition(mode: "original", pageKey: "original-5", pageIndex: 0),
        ReaderPosition(mode: "translated", pageKey: page.id.uuidString, pageIndex: 0),
    ] {
        #expect(
            ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading, position: position))
                == .reading(percent: 60))
    }
}

@Test func readingProgressHonorsExplicitUnreadAndFinishedStatuses() {
    let paper = progressPaper()
    let finalPage = ReaderPosition(mode: "original", pageKey: "original-9", pageIndex: 9)
    #expect(ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace()) == .notStarted)
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .unread, position: finalPage))
            == .notStarted)
    #expect(ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .finished)) == .finished)
    #expect(
        ReadingProgress.resolve(
            paper: paper,
            workspace: PaperWorkspace(
                status: .finished, position: ReaderPosition(mode: "original", pageKey: "original-0", pageIndex: 0)))
            == .finished)
}

@Test(arguments: ["original", "reflow", "translated"])
func readingProgressFinishesOnlyAtResolvedFinalSourcePage(mode: String) {
    var paper = progressPaper()
    let last = PageArtifact(blockIDs: [], sourcePage: 9, relativePath: "last.pdf")
    let earlier = PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "first.pdf")
    if mode == "reflow" { paper.previewPages = [last, earlier] }
    if mode == "translated" { paper.translatedPages = [last, earlier] }
    let position = ReaderPosition(
        mode: mode, pageKey: mode == "original" ? "original-9" : last.id.uuidString, pageIndex: 99)
    let progress = ReadingProgress.resolve(
        paper: paper, workspace: PaperWorkspace(status: .reading, position: position))
    #expect(progress == .finished)
    #expect(progress.readingStatus == .finished)
    #expect(progress.label == "已读")
    #expect(progress.fraction == 1)
}

@Test(arguments: ["missing", "original-10", "original--1", "original-09"])
func readingProgressDoesNotGuessUnknownOrInvalidPageKeys(pageKey: String) {
    let position = ReaderPosition(mode: "original", pageKey: pageKey, pageIndex: 9)
    #expect(
        ReadingProgress.resolve(paper: progressPaper(), workspace: PaperWorkspace(status: .reading, position: position))
            == .reading(percent: nil))
}

@Test(arguments: [-1, 10])
func readingProgressDoesNotCompleteInvalidArtifactSourcePages(sourcePage: Int) {
    var paper = progressPaper()
    let page = PageArtifact(blockIDs: [], sourcePage: sourcePage, relativePath: "invalid.pdf")
    paper.previewPages = [page]
    let position = ReaderPosition(mode: "reflow", pageKey: page.id.uuidString, pageIndex: 9)
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading, position: position))
            == .reading(percent: nil))
}

@Test(arguments: [0, -1])
func readingProgressDoesNotCompleteWithoutAPositivePageCount(pageCount: Int) {
    var paper = progressPaper()
    paper.pageCount = pageCount
    let finalPage = ReaderPosition(mode: "original", pageKey: "original-9", pageIndex: 9)
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading, position: finalPage))
            == .reading(percent: nil))
}

@Test func readingProgressMapsStatusesWithoutInventingMissingProgress() {
    #expect(ReadingProgress.notStarted.readingStatus == .unread)
    #expect(ReadingProgress.reading(percent: 40).readingStatus == .reading)
    let progress = ReadingProgress.resolve(paper: progressPaper(), workspace: PaperWorkspace(status: .reading))
    #expect(progress == .reading(percent: nil))
    #expect(progress.readingStatus == .reading)
}

private func progressPaper() -> Paper {
    Paper(
        title: "A local example", digest: "fixture", originalPath: "original.pdf", pageCount: 10,
        blocks: [], warnings: [], canReflow: true)
}
