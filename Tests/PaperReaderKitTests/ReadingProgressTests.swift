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

@Test func readingProgressDoesNotInferCompletionOrGuessMissingPages() {
    var paper = progressPaper()
    let finalPage = ReaderPosition(mode: "original", pageKey: "original-9", pageIndex: 9)
    #expect(ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace()) == .notStarted)
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading, position: finalPage))
            == .reading(percent: 100))
    #expect(ReadingProgress.reading(percent: 100).label == "读到 100%")
    #expect(ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .finished)) == .finished)
    paper.pageCount = 0
    #expect(
        ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading, position: finalPage))
            == .reading(percent: nil))
}

private func progressPaper() -> Paper {
    Paper(
        title: "A local example", digest: "fixture", originalPath: "original.pdf", pageCount: 10,
        blocks: [], warnings: [], canReflow: true)
}
