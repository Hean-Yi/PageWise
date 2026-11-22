#if os(macOS)
    import PDFKit
    import PaperReaderKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

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
