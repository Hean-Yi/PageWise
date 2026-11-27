import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test func quickStartChoosingAPaperAdvancesWithoutUsingItAsTheSample() {
    var guide = QuickStartNavigation(step: .importPaper)
    guide.didChooseLibraryPaper()
    #expect(guide.step == .modelSettings && guide.sampleID == nil)
    guide.request(.bilingual, closeReadingActive: false)
    guide.didChooseLibraryPaper()
    #expect(guide.step == .bilingual && guide.sampleID == nil)
}

@Test func quickStartWaitsForCloseReadingAndAllowsChangingDirection() {
    var guide = QuickStartNavigation(step: .assistant)
    guide.request(.modelSettings, closeReadingActive: true)
    #expect(guide.step == .assistant && guide.deferred == .modelSettings)
    guide.request(.noteHover, closeReadingActive: true)
    guide.resumeDeferredNavigation()
    #expect(guide.step == .noteHover && guide.deferred == nil)
    guide.request(.assistant, closeReadingActive: true)
    guide.request(.importPaper, closeReadingActive: true)
    guide.resumeDeferredNavigation()
    #expect(guide.step == .importPaper && guide.deferred == nil)
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

@Test func streamlinedQuickStartIncludesNoteRecordingAndHoverSteps() {
    #expect(QuickStartStep.allCases == [.importPaper, .modelSettings, .bilingual, .annotation, .noteHover, .assistant])
    #expect(QuickStartStep.noteHover.usesSample)
    #expect(!QuickStartStep.noteHover.requiresAnchor)
    #expect(QuickStartStep.annotation.requiresAnchor)
    #expect(QuickStartStep.annotation.instruction.contains("添加笔记"))
    #expect(QuickStartStep.noteHover.instruction.contains("悬停"))
    for step in QuickStartStep.allCases {
        #expect(!step.title.isEmpty && !step.instruction.isEmpty && !step.chapter.isEmpty)
    }
}
