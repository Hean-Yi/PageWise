#if os(macOS)
    import PDFKit
    import PaperReaderKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @MainActor private func hostLibrary(_ model: ReaderModel) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_100, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        return window
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

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

        try #require(await model.trashPaper(paperID))
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
