#if os(macOS)
    import AppKit
    import SwiftUI

    /// Only secondary clicks hit this view. The cover underneath still owns its primary drag sequence.
    struct ReaderSecondaryClick: NSViewRepresentable {
        let action: (ReaderMenuLocation) -> Void
        func makeNSView(context: Context) -> Target { Target() }
        func updateNSView(_ view: Target, context: Context) { view.action = action }

        final class Target: NSView {
            var action: ((ReaderMenuLocation) -> Void)?
            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? {
                guard let event = NSApp.currentEvent else { return nil }
                let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                let controlClick =
                    event.modifierFlags.contains(.control)
                    && (event.type == .leftMouseDown || event.type == .leftMouseUp)
                return secondary || controlClick ? super.hitTest(point) : nil
            }

            override func rightMouseDown(with event: NSEvent) {
                guard let location = ReaderMenuLocation(event: event) else { return }
                action?(location)
            }
            override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }
        }
    }
#endif
