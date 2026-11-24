import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test func quickStartChoosingAPaperKeepsTheFollowingLibrarySteps() {
    let imported = UUID()
    var guide = QuickStartNavigation(step: .importPaper)
    guide.chosePaper(imported)
    #expect(guide.step == .discovery && guide.paperID == imported)
    guide.request(.shelves, closeReadingActive: false)
    let selected = UUID()
    guide.chosePaper(selected)
    #expect(guide.step == .modelSettings && guide.paperID == selected)
    guide.request(.bilingual, closeReadingActive: false)
    guide.chosePaper(UUID())
    #expect(guide.step == .bilingual && guide.paperID == selected)
}

@Test func quickStartWaitsForCloseReadingAndAllowsChangingDirection() {
    var guide = QuickStartNavigation(step: .assistant, paperID: UUID())
    guide.request(.notebook, closeReadingActive: true)
    #expect(guide.step == .assistant && guide.deferred == .notebook)
    guide.request(.annotation, closeReadingActive: true)
    guide.resumeDeferredNavigation()
    #expect(guide.step == .annotation && guide.deferred == nil)
    guide.request(.assistant, closeReadingActive: true)
    guide.request(.notebook, closeReadingActive: true)
    guide.resumeDeferredNavigation()
    #expect(guide.step == .notebook && guide.deferred == nil)
}

@Test @MainActor func quickStartImportRetainsTheShelfAndAnnotationKeepsTheOriginalPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let pdf = root.appendingPathComponent("workflow.pdf")
    try DemoPaper.write(to: pdf)
    let imported = await reader.importURLs([pdf], selectAfterImport: false)
    let id = try #require(imported.last)
    #expect(reader.selectedPaperID == nil)
    var guide = QuickStartNavigation(step: .importPaper)
    guide.chosePaper(id)
    guide.request(.bilingual, closeReadingActive: false)
    reader.select(guide.paperID)
    reader.navigateToPage(1)
    #expect(reader.openBilingualReading(translatingDocument: false))
    #expect(reader.pdfBilingual.isOpen && reader.mode == "original")
    guide.request(.annotation, closeReadingActive: false)
    reader.showOriginalReading()
    #expect(!reader.pdfBilingual.isOpen && reader.visiblePage == 1 && reader.selectedPaperID == id)
}
