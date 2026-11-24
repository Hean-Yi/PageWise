#if os(macOS)
    import PDFKit
    import PaperReaderKit
    import SwiftUI
    import Testing
    import WebKit

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
        func update() { coordinator.update(original, penEnabled: false, focus: canvas.displayContext) }
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

        let host = NSHostingView(rootView: PDFCanvas(model: model, penEnabled: false, isReaderVisible: false))
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
        host.rootView = PDFCanvas(model: model, penEnabled: false, isReaderVisible: true)
        host.layoutSubtreeIfNeeded()
        #expect(original.currentPage === second)
        #expect(model.visiblePage == 1)

        // When the original is visible, its own page notifications drive reading position again.
        original.go(to: first)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: original)
        #expect(model.visiblePage == 0)
        await model.flushReadingPosition()
    }

    @Test @MainActor func selectingAnOriginalPDFQuoteOpensTheFloatingNoteActionAtItsExactRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("sample.pdf")
        try DemoPaper.write(to: file)
        _ = try #require(await model.importURLs([file]).first)

        let host = NSHostingView(
            rootView: PDFCanvas(model: model, penEnabled: false).environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 850), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        func findPDF(_ view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap(findPDF).first
        }
        func findPalette(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findPalette).first
        }
        func wait(_ description: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(12))
            }
            try #require(
                condition(), "\(description), selection: \(model.selectionText), ranges: \(model.pdfSelectionRanges)")
        }
        try await wait("PDF loaded") { findPDF(host)?.document?.pageCount == 2 && model.jumpPage == nil }
        let pdf = try #require(findPDF(host))
        let page = try #require(pdf.document?.page(at: 0))
        let text = try #require(page.string as NSString?)
        let range = text.range(of: "the Average")
        try #require(range.location != NSNotFound)
        let selection = try #require(page.selection(for: range))
        #expect(findPalette(host) == nil)
        pdf.setCurrentSelection(selection, animate: false)
        try await wait("Floating palette created") { findPalette(host) != nil }
        let web = try #require(findPalette(host))
        func js(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        func waitForMenu(_ script: String) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if (try? await js(script)) == true { return }
                try await Task.sleep(for: .milliseconds(15))
            }
            try #require(await js(script), "Native PDF palette: \(script)")
        }
        try await waitForMenu(
            "const m=document.querySelector('#annotation-menu'); return m && !m.hidden && !m.querySelector('.swatch').disabled"
        )
        #expect(model.pdfSelectionRanges == [range])
        #expect(
            try await js(
                "return document.querySelectorAll('.swatch').length===8 && document.querySelector('.add-note').textContent==='添加笔记'"
            ))
        #expect(try await js("document.querySelector('.add-note').click();return true"))
        try await wait("Draft opened") { model.pdfNoteEditor != nil }
        let anchor = try #require(model.pdfNoteEditor?.note.anchors.first)
        #expect(anchor.pdfPageIndex == 0 && anchor.start == range.location && anchor.end == NSMaxRange(range))
        #expect(anchor.text == "the Average")
        try await waitForMenu("return document.querySelector('#annotation-menu').hidden")
        model.closePDFReadingNote()
        pdf.clearSelection()
        pdf.setCurrentSelection(selection, animate: false)
        try await waitForMenu(
            "return document.querySelector('#annotation-menu')?.getBoundingClientRect().height>0"
        )
        // The same WebKit component is kept warm between selections.
        #expect(findPalette(host) === web)
        #expect(try await js("document.querySelector('[data-color=blue]').click();return true"))
        try await wait("Blue highlight persisted") { !model.currentHighlights.isEmpty }
        let highlight = try #require(model.currentHighlights.first)
        #expect(highlight.pdfTextStart == range.location && highlight.text == anchor.text)
        #expect(!highlight.rects.isEmpty && highlight.pageKey == anchor.key && highlight.color == .blue)
        try await waitForMenu(
            "return document.querySelector('.remove').hidden===false && document.querySelector('[data-color=blue]').getAttribute('aria-pressed')==='true'"
        )
        #expect(try await js("document.querySelector('[data-mode=underline]').click();return true"))
        try await wait("New underline visible") {
            model.currentHighlights.count == 1 && page.annotations.contains { $0.type == "Underline" }
                && !page.annotations.contains { $0.type == "Highlight" }
        }
        try await waitForMenu("return document.querySelector('.remove').textContent==='取消下划线'")
        #expect(try await js("document.querySelector('.remove').click();return true"))
        try await wait("Ink removed from original") { model.currentHighlights.isEmpty && page.annotations.isEmpty }
        #expect(try await js("document.querySelector('.bookmark').click();return true"))
        try await wait("Bookmark added") { model.currentBookmarks.count == 1 }
        await model.flushReadingPosition()
    }

    @Test func originalSelectionActionsFitAtViewportEdges() {
        let viewport = CGRect(x: 0, y: 0, width: 240, height: 300)
        let tools = CGSize(width: 142, height: 37)
        for selection in [
            CGRect(x: 3, y: 1, width: 16, height: 14), CGRect(x: 210, y: 282, width: 25, height: 17),
        ] {
            let origin = PDFSelectionToolsLayout.origin(for: tools, near: selection, in: viewport)
            let frame = CGRect(origin: origin, size: tools)
            #expect(viewport.contains(frame))
            #expect(!selection.intersects(frame))
        }
    }
#endif
