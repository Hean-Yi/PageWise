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
        private(set) var mouseDownEvent: NSEvent?
        private var dragged = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDownEvent = event
            dragged = false
            focusCover?()
            ShelfDragDiagnostics.record("source-down")
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let start = mouseDownPoint, let downEvent = mouseDownEvent, let paperID else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            dragged = true
            let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(paperID))
            draggingItem.setDraggingFrame(bounds, contents: dragImage())
            ShelfDragDiagnostics.record("source-begin start=\(start) point=\(point) window=\(event.locationInWindow)")
            // AppKit uses the initiating mouse-down location to calculate the drag image offset.
            let session = beginDraggingSession(with: [draggingItem], event: downEvent, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownPoint = nil
                mouseDownEvent = nil
            }
            guard !dragged, mouseDownPoint != nil else { return }
            ShelfDragDiagnostics.record("source-click")
            openPaper?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            // SwiftUI's closure-based onDrop may propose copy; the accepted domain
            // operation still performs a single-membership move after persistence.
            ShelfDragDiagnostics.record("source-mask context=\(context.rawValue)")
            return context == .withinApplication ? [.copy, .move] : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfDragDiagnostics.record("source-will-begin screen=\(screenPoint)")
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            ShelfDragDiagnostics.record("source-moved screen=\(screenPoint) cursor=\(NSEvent.mouseLocation)")
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseDownPoint = nil
            mouseDownEvent = nil
            ShelfDragDiagnostics.record(
                "\(operation.isEmpty ? "source-ended-none" : "source-ended-drop") screen=\(screenPoint) window=\(String(describing: window?.frame))"
            )
            ShelfDragDiagnostics.inspect(window: window, at: screenPoint)
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
    struct NativeShelfDrop: NSViewRepresentable {
        let activate: () -> Void
        let accepts: (UUID) -> Bool
        let receive: (UUID) -> Bool
        let highlight: (Bool) -> Void

        func makeNSView(context: Context) -> ShelfDropTargetView { ShelfDropTargetView() }
        func updateNSView(_ view: ShelfDropTargetView, context: Context) {
            view.activate = activate
            view.accepts = accepts
            view.receive = receive
            view.highlight = highlight
        }
    }

    final class ShelfDropTargetView: NSView {
        var activate: (() -> Void)?
        var accepts: ((UUID) -> Bool)?
        var receive: ((UUID) -> Bool)?
        var highlight: ((Bool) -> Void)?
        private var pressed = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.init(PaperShelfDrag.typeIdentifier)])
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { pressed = true }
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            activate?()
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            let allowed = reference(in: sender.draggingPasteboard) != nil
            ShelfDragDiagnostics.record("native-target-enter accepted=\(allowed) window=\(sender.draggingLocation)")
            highlight?(allowed)
            return allowed ? .move : []
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            reference(in: sender.draggingPasteboard) != nil ? .move : []
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            highlight?(false)
            ShelfDragDiagnostics.record("native-target-exit")
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            reference(in: sender.draggingPasteboard) != nil
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { highlight?(false) }
            guard let id = reference(in: sender.draggingPasteboard) else { return false }
            ShelfDragDiagnostics.record("native-target-perform")
            return receive?(id) ?? false
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { highlight?(false) }

        func reference(in pasteboard: NSPasteboard) -> UUID? {
            guard let data = pasteboard.data(forType: .init(PaperShelfDrag.typeIdentifier)),
                let id = PaperShelfDrag.paperID(from: data), accepts?(id) == true
            else { return nil }
            return id
        }
    }

#endif

/// Opt-in, content-free diagnostics for a local drag acceptance run.
enum ShelfDragDiagnostics {
    #if os(macOS)
        @MainActor static func inspect(window: NSWindow?, at point: NSPoint) {
            guard ProcessInfo.processInfo.environment["PAPERREADER_DEBUG_DRAG"] == "1", let window,
                let content = window.contentView
            else { return }
            let windowPoint = window.convertPoint(fromScreen: point)
            let hitPoint = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
            var hit = content.hitTest(hitPoint)
            record("hit-test active=\(NSApp.isActive) key=\(window.isKeyWindow) windowPoint=\(windowPoint)")
            for depth in 0..<10 {
                guard let view = hit else { break }
                record(
                    "hit[\(depth)] type=\(String(describing: type(of: view)).prefix(120)) rect=\(view.convert(view.bounds, to: nil)) types=\(view.registeredDraggedTypes.map(\.rawValue))"
                )
                hit = view.superview
            }
            var targets = 0
            func inspectTargets(_ view: NSView) {
                if view is ShelfDropTargetView {
                    targets += 1
                    record(
                        "native-target[\(targets)] rect=\(view.convert(view.bounds, to: nil)) hidden=\(view.isHiddenOrHasHiddenAncestor) types=\(view.registeredDraggedTypes.map(\.rawValue))"
                    )
                }
                for child in view.subviews { inspectTargets(child) }
            }
            inspectTargets(content)
        }
    #endif
    static func record(_ stage: String) {
        guard ProcessInfo.processInfo.environment["PAPERREADER_DEBUG_DRAG"] == "1" else { return }
        NSLog("PaperReader shelf-drag: %@", stage)
    }
}
