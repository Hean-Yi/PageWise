#if os(macOS)
    import PDFKit
    import PaperReaderKit
    import SwiftUI
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @MainActor private func hostLibrary(_ model: ReaderModel) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_100, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        return window
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test(arguments: [0.55, 1.0]) @MainActor
    func returningFromANotebookRestoresItsNativeScrollPosition(fraction: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let papers = (1...14).map {
            Paper(
                title: "Notebook fixture \($0)", digest: UUID().uuidString, originalPath: "fixture.pdf", pageCount: 1,
                blocks: [], warnings: [], canReflow: false)
        }
        model.state.papers = papers
        model.state.readingNotes = papers.map {
            var note = ReadingNote(
                paperID: $0.id, contentVersion: $0.digest + ":original-0", anchors: [], markdown: "阅读记录")
            note.placement = .documentEnd
            return note
        }
        model.selectedSection = "notebooks"
        let window = hostLibrary(model)
        defer { window.contentView = nil }
        let host = try #require(window.contentView)

        func findScrollableList() async throws -> NSScrollView {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                host.layoutSubtreeIfNeeded()
                for case let scroll as NSScrollView in descendants(of: host) {
                    guard scroll.contentSize.width > 400, let document = scroll.documentView else { continue }
                    if document.frame.height - scroll.contentSize.height > 100 { return scroll }
                }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            throw CancellationError()
        }

        let list = try await findScrollableList()
        let document = try #require(list.documentView)
        let travel = document.frame.height - list.contentSize.height
        let target = NSPoint(x: 0, y: travel * fraction)
        list.contentView.scroll(to: target)
        list.reflectScrolledClipView(list.contentView)
        try await Task.sleep(for: .milliseconds(80))
        let originalOffset = list.documentVisibleRect.minY
        try #require(originalOffset > 100)

        let note = try #require(model.state.readingNotes.last)
        model.select(note.paperID)
        model.openReadingNote(note)
        let leaveDeadline = ContinuousClock.now + .seconds(3)
        while descendants(of: host).contains(list), ContinuousClock.now < leaveDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!descendants(of: host).contains(list))
        model.returnFromReader()
        let restored = try await findScrollableList()
        let restoreDeadline = ContinuousClock.now + .seconds(3)
        while abs(restored.documentVisibleRect.minY - originalOffset) > 2, ContinuousClock.now < restoreDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(restored.documentVisibleRect.minY - originalOffset) <= 2)
        await model.flushReadingPosition()
    }

    @Test @MainActor func notebookOpensWithoutLoadingThePaperAndReusesAnAlreadyOpenedCanvas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("notes.pdf")
        try DemoPaper.write(to: file)
        let paperID = try #require(await model.importURLs([file]).first)
        let version = try #require(model.paper?.digest) + ":original-0"
        var note = ReadingNote(paperID: paperID, contentVersion: version, anchors: [], markdown: "本次阅读笔记")
        note.placement = .documentEnd
        model.state.readingNotes = [note]
        model.select(nil)
        model.selectedSection = "notebooks"
        let window = hostLibrary(model)
        defer { window.contentView = nil }
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()

        model.select(paperID)
        model.openReadingNote(note)
        func waitForView<V: NSView>(_ type: V.Type) async throws -> V {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let view = descendants(of: host).compactMap({ $0 as? V }).first { return view }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            return try #require(descendants(of: host).compactMap { $0 as? V }.first)
        }
        _ = try await waitForView(WKWebView.self)
        #expect(!descendants(of: host).contains { $0 is PDFView })
        model.closeDocumentSummary()
        let canvas = try await waitForView(PDFView.self)
        model.openReadingNote(note)
        _ = try await waitForView(WKWebView.self)
        #expect(descendants(of: host).compactMap { $0 as? PDFView } == [canvas])
        model.returnFromReader()
        #expect(model.selectedSection == "notebooks")
        await model.flushReadingPosition()
    }

    @Test @MainActor func rapidWorkspaceNavigationMountsOnlyTheCurrentPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("navigation.pdf")
        try DemoPaper.write(to: file)
        let paperID = try #require(await model.importURLs([file]).first)
        model.select(nil)

        let window = hostLibrary(model)
        defer { window.contentView = nil }
        let host = try #require(window.contentView)
        for (step, reading) in [false, true, false, true, false].enumerated() {
            // Interrupt the previous navigation before its animation has completed.
            withAnimation(.linear(duration: 1)) {
                if reading { model.select(paperID) } else { model.returnFromReader() }
            }
            // Observation schedules the view update on the next run-loop pass. Sample the
            // first layout containing the incoming surface, while the animation is active.
            var views: [NSView] = []
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                views = descendants(of: host)
                if views.contains(where: { reading ? $0 is PDFView : $0 is ShelfPreviewKeys.Monitor }) { break }
                try await Task.sleep(for: .milliseconds(5))
            } while ContinuousClock.now < deadline
            let canvases = views.compactMap { $0 as? PDFView }
            let shelves = views.compactMap { $0 as? ShelfPreviewKeys.Monitor }
            #expect(canvases.count == (reading ? 1 : 0), "Navigation step \(step)")
            #expect(shelves.count == (reading ? 0 : 1), "Navigation step \(step)")
            if reading { #expect(canvases.first?.document?.pageCount == 2) }
        }
        await model.flushReadingPosition()
    }

    @Test @MainActor func deletingAPreviewedPaperReleasesTheShelfForTheNextInteraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("preview.pdf")
        try DemoPaper.write(to: file)
        let paperID = try #require(await model.importURLs([file]).first)
        model.select(nil)
        let window = hostLibrary(model)
        defer { window.contentView = nil }
        let host = try #require(window.contentView)

        let deadline = ContinuousClock.now + .seconds(3)
        var monitor: ShelfPreviewKeys.Monitor?
        var presented = false
        repeat {
            host.layoutSubtreeIfNeeded()
            monitor = descendants(of: host).compactMap { $0 as? ShelfPreviewKeys.Monitor }.first
            presented = monitor?.actions?.press(paperID) == true
            if !presented { try await Task.sleep(for: .milliseconds(10)) }
        } while !presented && ContinuousClock.now < deadline
        try #require(presented)

        let paper = try #require(model.state.papers.first { $0.id == paperID })
        let deletion = PaperDeletionRequest(paper, model: model)
        #expect(deletion.title == paper.title)
        #expect(model.state.papers.contains { $0.id == paperID })
        await deletion.confirm()
        try #require(!model.state.papers.contains { $0.id == paperID })
        let removalDeadline = ContinuousClock.now + .seconds(3)
        while descendants(of: host).contains(where: { ($0 as? PaperDragSourceView)?.paperID == paperID }),
            ContinuousClock.now < removalDeadline
        {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor?.actions?.dismiss() == false)
        await model.flushReadingPosition()
    }
#endif
