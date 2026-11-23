#if os(macOS)
    import PDFKit
    import PaperReaderKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @Test @MainActor func originalCanvasReleasesSourceWhileWaitingAndReportsMissingPublishedPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("sample.pdf")
        try DemoPaper.write(to: file)
        var paper = Paper(
            title: "Source with PDF", digest: "fixture", originalPath: file.lastPathComponent, pageCount: 2,
            blocks: [], warnings: [], canReflow: true)
        paper.onlineSource = OnlinePaperSource(candidateID: "fixture")
        model.state.papers = [paper]
        model.select(paper.id)
        #expect(model.showsPDFCanvas)
        model.pdfBilingual.open(model, translatingDocument: true)
        let canvas = PDFCanvas(model: model, penEnabled: false)
        let coordinator = PDFCoordinator(model: model)
        let original = coordinator.makeView()
        func update() { coordinator.update(original, penEnabled: false, focus: canvas.sentenceDisplay) }
        update()
        #expect(!model.pdfBilingual.isOpen && original.document?.pageCount == paper.pageCount)

        // Deliver the extra update that SwiftUI can send to the original representable during the transition.
        model.mode = "translated"
        model.translating.insert(paper.id)
        update()
        #expect(original.document == nil)
        #expect(model.message == nil)

        // A missing published fixed page should still surface an error while it is selected.
        model.state.papers[0].translatedPages = [PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "missing.pdf")]
        model.translating.remove(paper.id)
        update()
        model.translating.insert(paper.id)
        await Task.yield()
        #expect(model.message == nil)
        update()
        model.translating.remove(paper.id)
        update()
        for _ in 0..<50 where model.message == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.message?.contains("PDF 页面缺失或无法打开") == true)
    }

    @Test @MainActor func hiddenOriginalDefersNavigationToTheVisibleReadingSurface() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("sample.pdf")
        try DemoPaper.write(to: file)
        _ = try #require(await model.importURLs([file]).first)

        let host = NSHostingView(rootView: PDFCanvas(model: model, penEnabled: false, acceptsSentenceInput: false))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 350),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func pdfView(in view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }
        let original = try #require(pdfView(in: host))
        let document = try #require(original.document)
        let first = try #require(document.page(at: 0))
        let second = try #require(document.page(at: 1))

        model.navigateToPage(1)
        host.layoutSubtreeIfNeeded()
        original.go(to: first)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: original)
        await Task.yield()
        #expect(model.visiblePage == 1)
        #expect(model.jumpPage == 1)

        // The continuous text view accepts the jump, then the user peeks at the source page.
        model.jumpPage = nil
        host.rootView = PDFCanvas(model: model, penEnabled: false, acceptsSentenceInput: true)
        host.layoutSubtreeIfNeeded()
        #expect(original.currentPage === second)
        #expect(model.visiblePage == 1)

        // When the original is visible, its own page notifications drive reading position again.
        original.go(to: first)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: original)
        #expect(model.visiblePage == 0)
        await model.flushReadingPosition()
    }
#endif
