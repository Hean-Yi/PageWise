#if os(macOS)
    import AppKit
    import SwiftUI

    /// A hover gesture must work without first clicking or moving keyboard focus to the cover.
    struct ShelfPreviewKeys: NSViewRepresentable {
        var selectedShelfID: UUID?
        var hovered: (CGPoint) -> UUID? = { _ in nil }
        let press: (UUID) -> Bool
        let release: () -> Bool
        let dismiss: () -> Bool

        func makeNSView(context: Context) -> Monitor { Monitor() }
        func updateNSView(_ view: Monitor, context: Context) {
            // Switching shelves can leave the previous text editor active even after its content is gone.
            if let previous = view.actions, previous.selectedShelfID != selectedShelfID, let window = view.window,
                (window.firstResponder as? NSText)?.isEditable == true
            {
                window.makeFirstResponder(nil)
            }
            view.actions = self
        }

        final class Monitor: NSView {
            var actions: ShelfPreviewKeys?
            private var eventMonitor: Any?
            private var ownsSpace = false
            override var isFlipped: Bool { true }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                eventMonitor = nil
                NotificationCenter.default.removeObserver(self)
                ownsSpace = false
                guard let window else { return }
                NotificationCenter.default.addObserver(
                    self, selector: #selector(lostFocus), name: NSWindow.didResignKeyNotification, object: window)
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            }

            @objc private func lostFocus() {
                ownsSpace = false
                _ = actions?.release()
            }

            func handle(_ event: NSEvent) -> Bool {
                guard let window, window === event.window, window.isKeyWindow, window.attachedSheet == nil,
                    let actions
                else { return false }
                if event.keyCode == 53, event.type == .keyDown { return actions.dismiss() }
                guard event.keyCode == 49 else { return false }
                if event.type == .keyUp {
                    let released = actions.release()
                    defer { ownsSpace = false }
                    return ownsSpace || released
                }
                if event.isARepeat { return ownsSpace }
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    NSEvent.pressedMouseButtons == 0, (window.firstResponder as? NSText)?.isEditable != true,
                    let content = window.contentView
                else { return false }
                let point = window.mouseLocationOutsideOfEventStream
                let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                let local = convert(point, from: nil)
                // SwiftUI may hit the scroll document until the pointer moves over a newly laid out cover.
                let measured = bounds.contains(local) ? actions.hovered(local) : nil
                guard let id = measured ?? (hit as? PaperDragSourceView)?.paperID else { return false }
                ownsSpace = actions.press(id)
                return ownsSpace
            }
        }
    }
#endif
