#if os(macOS)
    import AppKit
    import Testing

    @testable import PaperReaderUI

    @MainActor private final class PointedWindow: NSWindow {
        var pointer = CGPoint(x: 50, y: 40)
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var isKeyWindow: Bool { true }
    }

    @Test @MainActor func holdingSpaceOverACoverReleasesTheSamePreviewAndPreservesTextInput() throws {
        _ = NSApplication.shared
        let window = PointedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let cover = PaperDragSourceView(frame: NSRect(x: 10, y: 10, width: 100, height: 140))
        let paperID = UUID()
        cover.paperID = paperID
        content.addSubview(cover)
        let monitor = ShelfPreviewKeys.Monitor(frame: .zero)
        content.addSubview(monitor)
        defer { monitor.removeFromSuperview() }
        var pressed: [UUID] = []
        var presented = false
        monitor.actions = .init(
            press: {
                pressed.append($0)
                presented = true
                return true
            },
            release: {
                defer { presented = false }
                return presented
            },
            dismiss: {
                presented = false
                return true
            })
        func key(_ type: NSEvent.EventType, repeated: Bool = false, flags: NSEvent.ModifierFlags = []) throws -> NSEvent
        {
            try #require(
                NSEvent.keyEvent(
                    with: type, location: window.pointer, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: repeated, keyCode: 49))
        }
        #expect(try !monitor.handle(key(.keyDown, flags: .command)))
        #expect(try monitor.handle(key(.keyDown)))
        #expect(pressed == [paperID] && presented)
        window.pointer = .init(x: 250, y: 100)
        #expect(try monitor.handle(key(.keyDown, repeated: true)))
        #expect(try monitor.handle(key(.keyUp)))
        #expect(pressed == [paperID] && !presented)
        #expect(try !monitor.handle(key(.keyDown)))
        let editor = NSTextView(frame: NSRect(x: 200, y: 0, width: 100, height: 100))
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        window.pointer = .init(x: 50, y: 40)
        #expect(try !monitor.handle(key(.keyDown)))
        #expect(pressed == [paperID])
    }
#endif
