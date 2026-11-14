import Foundation

#if os(macOS)
    import AppKit
    import SwiftUI

    /// AppKit owns the mouse sequence; SwiftUI buttons and scroll gestures cannot consume it.
    struct NativePaperDrag: NSViewRepresentable {
        let paperID: UUID
        let focus: () -> Void
        let open: () -> Void

        func makeNSView(context: Context) -> PaperDragSourceView { PaperDragSourceView() }

        func updateNSView(_ view: PaperDragSourceView, context: Context) {
            view.paperID = paperID
            view.focusCover = focus
            view.openPaper = open
        }
    }

    final class PaperDragSourceView: NSView, NSDraggingSource {
        var paperID: UUID?
        var focusCover: (() -> Void)?
        var openPaper: (() -> Void)?
        private var mouseDownPoint: NSPoint?
        private var dragged = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            dragged = false
            focusCover?()
            ShelfDragDiagnostics.record("source-down")
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let start = mouseDownPoint, let paperID else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            dragged = true
            let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(paperID))
            draggingItem.setDraggingFrame(bounds, contents: dragImage())
            ShelfDragDiagnostics.record("source-begin")
            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownPoint = nil }
            guard !dragged, mouseDownPoint != nil else { return }
            ShelfDragDiagnostics.record("source-click")
            openPaper?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            // SwiftUI's closure-based onDrop may propose copy; the accepted domain
            // operation still performs a single-membership move after persistence.
            context == .withinApplication ? [.copy, .move] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseDownPoint = nil
            ShelfDragDiagnostics.record(operation.isEmpty ? "source-ended-none" : "source-ended-drop")
        }

        static func pasteboardItem(_ paperID: UUID) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setData(Data(paperID.uuidString.utf8), forType: .init(PaperShelfDrag.typeIdentifier))
            return item
        }

        private func dragImage() -> NSImage {
            // Snapshot only the visible cover under this transparent interaction surface.
            if let parent = superview {
                let rect = convert(bounds, to: parent)
                if let bitmap = parent.bitmapImageRepForCachingDisplay(in: rect) {
                    parent.cacheDisplay(in: rect, to: bitmap)
                    let image = NSImage(size: bounds.size)
                    image.addRepresentation(bitmap)
                    return image
                }
            }
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage(size: bounds.size)
        }
    }
#endif

/// Opt-in, content-free diagnostics for a local drag acceptance run.
enum ShelfDragDiagnostics {
    static func record(_ stage: String) {
        guard ProcessInfo.processInfo.environment["PAPERREADER_DEBUG_DRAG"] == "1" else { return }
        NSLog("PaperReader shelf-drag: %@", stage)
    }
}
