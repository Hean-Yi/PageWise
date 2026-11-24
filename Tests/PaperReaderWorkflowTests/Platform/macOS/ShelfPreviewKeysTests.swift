#if os(macOS)
    import AppKit
    import PaperReaderKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @MainActor private final class PointedWindow: NSWindow {
        var pointer = CGPoint(x: 50, y: 40)
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var isKeyWindow: Bool { true }
    }

    @MainActor @Observable private final class ShelfChoice {
        var id: UUID?
    }

    @Test(arguments: [true, false])
    @MainActor func spaceOverANewlySelectedTopicFindsTheCoverWithoutMovingTheMouse(editingSearch: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let shelf = try #require(await model.createShelf(name: "Methods"))
        let file = root.appendingPathComponent("sample.pdf")
        try DemoPaper.write(to: file)
        let paper = try #require(await model.importURLs([file], selectAfterImport: false, shelfID: shelf).first)
        let unfiled = Paper(
            title: "Unclassified fixture", digest: UUID().uuidString, originalPath: "unused.pdf", pageCount: 1,
            blocks: [], warnings: [], canReflow: false)
        model.state.papers.append(unfiled)
        let window = PointedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1150, height: 720), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        let choice = ShelfChoice()
        let shelfBinding = Binding<UUID?>(get: { choice.id }, set: { choice.id = $0 })
        window.contentView = NSHostingView(
            rootView: LibraryWorkspaceView(
                model: model, collection: .constant(.all), selectedShelfID: shelfBinding,
                onlineSearch: OnlinePaperSearch(reader: model), findRequest: 0, openSample: {}))
        defer { window.contentView = nil }
        let host = try #require(window.contentView)
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let deadline = ContinuousClock.now + .seconds(4)
        var targets = [ShelfDropTargetView]()
        repeat {
            host.layoutSubtreeIfNeeded()
            targets = children(host).compactMap { $0 as? ShelfDropTargetView }
            if targets.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        try #require(targets.count == 2)
        let target = try #require(
            targets.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        if editingSearch {
            let search = try #require(children(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            try #require(window.makeFirstResponder(search))
            try #require((window.firstResponder as? NSText)?.isEditable == true)
        }
        func click(_ type: NSEvent.EventType, on button: ShelfDropTargetView) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: button.convert(.zero, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 0))
        }
        let other = try #require(targets.first { $0 !== target })
        for button in [target, other, target] {
            button.mouseDown(with: try click(.leftMouseDown, on: button))
            button.mouseUp(with: try click(.leftMouseUp, on: button))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        // Picking the active topic must also exit search even though the selection ID stays equal.
        if editingSearch {
            let search = try #require(children(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            try #require(window.makeFirstResponder(search))
            target.mouseDown(with: try click(.leftMouseDown, on: target))
            target.mouseUp(with: try click(.leftMouseUp, on: target))
            #expect((window.firstResponder as? NSText)?.isEditable != true)
        }
        var cover: PaperDragSourceView?
        repeat {
            host.layoutSubtreeIfNeeded()
            cover = children(host).compactMap { $0 as? PaperDragSourceView }.first { $0.paperID == paper }
            if cover != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let visibleCover = try #require(cover)
        #expect(choice.id == shelf)
        #expect(!children(host).contains { ($0 as? PaperDragSourceView)?.paperID == unfiled.id })
        let frame = visibleCover.convert(visibleCover.bounds, to: nil)
        window.pointer = CGPoint(x: frame.midX, y: frame.midY)
        let monitor = try #require(children(host).compactMap { $0 as? ShelfPreviewKeys.Monitor }.first)
        func space(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49))
        }
        // Deliberately send no mouse-entered/moved event after switching the grid.
        #expect(try monitor.handle(space(.keyDown)))
        #expect(try monitor.handle(space(.keyUp)))
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
