#if os(macOS)
    import AppKit
    import PaperReaderKit
    import Testing

    @testable import PaperReaderUI

    @MainActor @Test func nativeCoverClickPreservesFocusAndOpenWithoutAButton() throws {
        let view = PaperDragSourceView(frame: NSRect(x: 0, y: 0, width: 180, height: 250))
        var focusCount = 0
        var openCount = 0
        view.focusCover = { focusCount += 1 }
        view.openPaper = { openCount += 1 }
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 50, y: 70), modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: 50, y: 70), modifierFlags: [], timestamp: 2,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        #expect(view.mouseDownEvent === down)
        #expect(view.mouseDownEvent?.type == .leftMouseDown)
        #expect(focusCount == 1)
        #expect(openCount == 0)
        view.mouseUp(with: up)
        #expect(view.mouseDownEvent == nil)
        #expect(openCount == 1)
        // A stray mouse-up cannot open the paper a second time.
        view.mouseUp(with: up)
        #expect(view.mouseDownEvent == nil)
        #expect(openCount == 1)
    }

    @MainActor @Test func nativeDraggingAdvertisesOnlyValidatedPaperReferenceData() throws {
        let id = UUID()
        let item = PaperDragSourceView.pasteboardItem(id)
        #expect(item.types == [.init(PaperShelfDrag.typeIdentifier)])
        let data = try #require(item.data(forType: .init(PaperShelfDrag.typeIdentifier)))
        #expect(PaperShelfDrag.paperID(from: data) == id)
        #expect(item.string(forType: .fileURL) == nil)
        #expect(item.string(forType: .string) == nil)
    }

    @MainActor @Test func nativeDropTargetRejectsForeignOrUnknownReferences() throws {
        let knownID = UUID()
        let target = ShelfDropTargetView(frame: NSRect(x: 0, y: 0, width: 180, height: 160))
        target.accepts = { $0 == knownID }
        #expect(target.registeredDraggedTypes == [.init(PaperShelfDrag.typeIdentifier)])
        let pasteboard = NSPasteboard(name: .init("PaperReader-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([PaperDragSourceView.pasteboardItem(knownID)])
        #expect(target.reference(in: pasteboard) == knownID)
        pasteboard.clearContents()
        pasteboard.writeObjects([PaperDragSourceView.pasteboardItem(UUID())])
        #expect(target.reference(in: pasteboard) == nil)
        pasteboard.clearContents()
        pasteboard.setString("unrelated", forType: .string)
        #expect(target.reference(in: pasteboard) == nil)
        pasteboard.setData(Data("malformed".utf8), forType: .init(PaperShelfDrag.typeIdentifier))
        #expect(target.reference(in: pasteboard) == nil)
    }

    @MainActor @Test func nativeDropSurfacePreservesShelfActivation() throws {
        let target = ShelfDropTargetView(frame: NSRect(x: 0, y: 0, width: 180, height: 160))
        var activations = 0
        target.activate = { activations += 1 }
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 2,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        target.mouseUp(with: up)
        #expect(activations == 0)
        target.mouseDown(with: down)
        target.mouseUp(with: up)
        #expect(activations == 1)
    }
    @MainActor @Test func nativeCoverPreviewRendersOpaqueBookAndTransparentShadowMargin() throws {
        let paper = Paper(
            title: "Original Drag Preview Fixture", digest: "cover-image-test", originalPath: "fixture.pdf",
            pageCount: 2,
            blocks: [], warnings: [], canReflow: false)
        let progress = ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .finished))
        let image = try #require(
            CoverDragImage.render(paper: paper, progress: progress, size: CGSize(width: 210, height: 300)))
        #expect(image.size == CGSize(width: 258, height: 348))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let corner = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(center.alphaComponent > 0.99)
        #expect(corner.alphaComponent < 0.1)
        // A transparent parent snapshot or generic document icon cannot fill the book interior.
        var opaque = 0
        for x in stride(from: bitmap.pixelsWide / 5, to: bitmap.pixelsWide * 4 / 5, by: 12) {
            for y in stride(from: bitmap.pixelsHigh / 5, to: bitmap.pixelsHigh * 4 / 5, by: 12) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 { opaque += 1 }
            }
        }
        #expect(opaque > 100)
        #expect(CoverDragImage.render(paper: paper, progress: progress, size: .zero) == nil)
    }

    @MainActor @Test func nativeCoverDestinationSharesSourceSurfaceAndEndClearsTransientState() throws {
        let id = UUID()
        let view = PaperDragSourceView(frame: NSRect(x: 0, y: 0, width: 180, height: 250))
        view.accepts = { $0 == id }
        #expect(view.registeredDraggedTypes == [.init(PaperShelfDrag.typeIdentifier)])
        let pasteboard = NSPasteboard(name: .init("PaperReader-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([PaperDragSourceView.pasteboardItem(id)])
        #expect(view.reference(in: pasteboard) == id)
        view.accepts = { _ in false }
        #expect(view.reference(in: pasteboard) == nil)
        var ended = false
        view.end = { ended = true }
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(view.mouseDownEvent != nil)
        view.finishDrag()
        #expect(view.mouseDownEvent == nil)
        #expect(ended)
    }
#endif
