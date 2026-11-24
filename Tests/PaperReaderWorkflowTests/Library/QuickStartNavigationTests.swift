import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test func quickStartChoosingAPaperAdvancesWithoutUsingItAsTheSample() {
    var guide = QuickStartNavigation(step: .importPaper)
    guide.didChooseLibraryPaper()
    #expect(guide.step == .discovery && guide.sampleID == nil)
    guide.request(.shelves, closeReadingActive: false)
    guide.didChooseLibraryPaper()
    #expect(guide.step == .modelSettings && guide.sampleID == nil)
    guide.request(.bilingual, closeReadingActive: false)
    guide.didChooseLibraryPaper()
    #expect(guide.step == .bilingual && guide.sampleID == nil)
}

@Test func quickStartWaitsForCloseReadingAndAllowsChangingDirection() {
    var guide = QuickStartNavigation(step: .assistant)
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

@Test @MainActor func quickStartSampleAnnotationKeepsItsOriginalPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    #expect(reader.selectedPaperID == nil)
    var guide = QuickStartNavigation(step: .importPaper)
    guide.request(.bilingual, closeReadingActive: false)
    let id = try #require(await reader.openBundledSample())
    reader.navigateToPage(1)
    #expect(reader.openBilingualReading(translatingDocument: false))
    #expect(reader.pdfBilingual.isOpen && reader.mode == "original")
    guide.request(.annotation, closeReadingActive: false)
    reader.showOriginalReading()
    #expect(!reader.pdfBilingual.isOpen && reader.visiblePage == 1 && reader.selectedPaperID == id)
}
