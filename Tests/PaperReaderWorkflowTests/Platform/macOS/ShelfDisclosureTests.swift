#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

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
        func waitForRows(wrapped: Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while (rowCount() > 1) != wrapped, ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
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
        // NSEvent(cgEvent:) otherwise inherits the real mouse position, which may be over
        // another window. Keep the gesture at one screen point as the tab slides underneath.
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: point)
        let primary = try #require(NSScreen.screens.first)
        let pointer = CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
        for phase in [CGScrollPhase.began, .changed, .ended] {
            let wheel = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                    wheel2: phase == .changed ? -Int32(document.bounds.width.rounded(.up)) : 0, wheel3: 0))
            wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            wheel.location = pointer
            let event = try #require(NSEvent(cgEvent: wheel))
            target.scrollWheel(with: event)
            try await Task.sleep(for: .milliseconds(20))
        }
        let endOffset = document.bounds.width - scroll.contentSize.width
        let deadline = ContinuousClock.now + .seconds(2)
        while scroll.contentView.bounds.minX < endOffset - 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(scroll.contentView.bounds.minX - endOffset) <= 1)
        #expect(try await button("新建书架").accessibilityFrame?() == add)
        #expect(expand.accessibilityPerformPress?() == true)

        let collapse = try await button("收起书架")
        try await waitForRows(wrapped: true)
        #expect(rowCount() > 1)
        #expect(descendants(host).contains { $0 === target })
        #expect(try await button("新建书架").accessibilityFrame?() == add)
        #expect(collapse.accessibilityPerformPress?() == true)
        _ = try await button("展开全部书架")
        try await waitForRows(wrapped: false)
        #expect(rowCount() == 1)
        #expect(descendants(host).contains { $0 === target })
        #expect(try await button("新建书架").accessibilityFrame?() == add)
    }
#endif
