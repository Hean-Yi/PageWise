#if os(macOS)
    import AppKit
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
        #expect(focusCount == 1)
        #expect(openCount == 0)
        view.mouseUp(with: up)
        #expect(openCount == 1)
        // A stray mouse-up cannot open the paper a second time.
        view.mouseUp(with: up)
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
#endif
