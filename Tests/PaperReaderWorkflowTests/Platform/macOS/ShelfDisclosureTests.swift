#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    private final class ShelfScrollEvent: NSEvent {
        var distance: CGFloat = 0
        override var type: NSEvent.EventType { .scrollWheel }
        override var scrollingDeltaX: CGFloat { distance }
        override var scrollingDeltaY: CGFloat { 0 }
        override var deltaX: CGFloat { distance }
        override var deltaY: CGFloat { 0 }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var phase: NSEvent.Phase { .changed }
        override var momentumPhase: NSEvent.Phase { [] }
        override var modifierFlags: NSEvent.ModifierFlags { [] }
        override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    }

    @Test @MainActor func shelfDisclosureWrapsOnlyOnRequestAndKeepsAddAtTheTrailingEdge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        for number in 1...8 { _ = try #require(await model.createShelf(name: "Research topic \(number)")) }
        let size = CGSize(width: 420, height: 280)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(
            rootView: TopicShelvesView(model: model, selectedShelfID: .constant(nil)) { Text("排序") }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.accessibilityEnabled, true))
        window.contentView = host
        defer { window.contentView = nil }

        func control(_ label: String, in element: AnyObject) -> AnyObject? {
            if element.accessibilityLabel?() == label { return element }
            for child in element.accessibilityChildren?() ?? [] {
                if let found = control(label, in: child as AnyObject) { return found }
            }
            return nil
        }
        func button(_ label: String) async throws -> AnyObject {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let node = control(label, in: host) { return node }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            return try #require(control(label, in: host))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rowCount() -> Int {
            let targets = descendants(host).compactMap { $0 as? ShelfDropTargetView }
            return Set(targets.map { $0.convert($0.bounds, to: host).midY.rounded() }).count
        }
        let expand = try await button("展开全部书架")
        let add = try #require(try await button("新建书架").accessibilityFrame?())
        let disclosure = try #require(expand.accessibilityFrame?())
        #expect(add.minX >= disclosure.maxX)
        #expect(rowCount() == 1)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        try #require(document.bounds.width > scroll.contentSize.width)
        let target = try #require(descendants(host).compactMap { $0 as? ShelfDropTargetView }.first)
        let event = ShelfScrollEvent()
        event.distance = -document.bounds.width
        target.scrollWheel(with: event)
        let endOffset = document.bounds.width - scroll.contentSize.width
        let deadline = ContinuousClock.now + .seconds(2)
        while scroll.contentView.bounds.minX < endOffset - 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(scroll.contentView.bounds.minX - endOffset) <= 1)
        #expect(try await button("新建书架").accessibilityFrame?() == add)
        #expect(expand.accessibilityPerformPress?() == true)

        let collapse = try await button("收起书架")
        #expect(rowCount() > 1)
        #expect(try await button("新建书架").accessibilityFrame?() == add)
        #expect(collapse.accessibilityPerformPress?() == true)
        _ = try await button("展开全部书架")
        #expect(rowCount() == 1)
        #expect(try await button("新建书架").accessibilityFrame?() == add)
    }
#endif
