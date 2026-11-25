#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import PaperReaderUI

    /// Exercise the real representable and menu button without ordering an AppKit popover onto the user's screen.
    @MainActor private final class RecordedMenuPopover: NSPopover {
        var anchors: [NSView] = []
        var rectangles: [NSRect] = []
        var edges: [NSRectEdge] = []
        var closes = 0

        override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
            anchors.append(positioningView)
            rectangles.append(positioningRect)
            edges.append(preferredEdge)
        }

        override func performClose(_ sender: Any?) {
            closes += 1
            delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
        }
    }

    @Test @MainActor func menuAnchorPresentsOncePerOpeningAcrossLayoutUpdates() async throws {
        var open = false
        var reads = 0
        var opened: [RecordedMenuPopover] = []
        var actions: [String] = []
        let binding = Binding(
            get: {
                reads += 1
                return open
            },
            set: { open = $0 })

        func anchor(_ title: String) -> ReaderMenuAnchor {
            var anchor = ReaderMenuAnchor(
                open: binding, title: title,
                items: { [.action(title) { actions.append(title) }] },
                width: 208, point: nil)
            anchor.makePopover = {
                let popup = RecordedMenuPopover()
                opened.append(popup)
                return popup
            }
            return anchor
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered,
            defer: false)
        let host = NSHostingView(rootView: anchor("关闭"))
        window.contentView = host
        defer { window.contentView = nil }

        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition())
        }
        func render(_ title: String) async throws {
            let lastRead = reads
            host.rootView = anchor(title)
            try await wait { reads > lastRead }
        }
        func button(named name: String, in element: AnyObject) -> AnyObject? {
            if element.accessibilityRole?() == .button, element.accessibilityLabel?() == name { return element }
            for child in element.accessibilityChildren?() ?? [] {
                if let match = button(named: name, in: child as AnyObject) { return match }
            }
            return nil
        }

        open = true
        try await render("第一次")
        try await wait { opened.first?.anchors.count == 1 }
        let first = try #require(opened.first)
        for update in 1...4 { try await render("更新 \(update)") }
        #expect(opened.count == 1 && first.anchors.count == 1)
        #expect(actions.isEmpty)

        // AppKit can close a transient popup without any action (for example, an outside click).
        first.performClose(nil)
        try await wait { !open }
        #expect(actions.isEmpty)
        try await render("关闭")
        open = true
        try await render("第二次")
        try await wait { opened.count == 2 && opened[1].anchors.count == 1 }
        let second = opened[1]
        #expect(first !== second && second.anchors.count == 1 && first.anchors.first === second.anchors.first)
        let panel = try #require(second.contentViewController as? NSHostingController<ReaderMenuPanel>)
        let rows = NSHostingView(rootView: panel.rootView.environment(\.accessibilityEnabled, true))
        rows.frame = window.contentLayoutRect
        host.addSubview(rows)
        try await wait { button(named: "第二次", in: rows) != nil }
        let action = try #require(button(named: "第二次", in: rows))
        #expect(action.accessibilityPerformPress?() == true)
        try await wait { !open }
        try await render("已关闭")
        #expect(actions == ["第二次"])
        #expect(first.closes == 1 && second.closes == 1 && opened.count == 2)
        #expect(!window.isVisible)
    }

    @Test @MainActor func coverOptionsUseTheVisibleButtonOrClickPointAndFitTheirRows() async throws {
        let buttonSize = NSSize(width: 30, height: 30)
        let requestedPoint = CGPoint(x: 6, y: 22)
        let items: [ReaderMenuItem] = [
            .submenu("移动到书架", icon: .library, items: [.action("未分类") {}]),
            .submenu("阅读状态", icon: .read, items: [.action("已读") {}]),
            .divider, .action("删除论文…", icon: .delete, destructive: true) {},
        ]
        for clickPoint in [nil, requestedPoint] {
            var open = false
            let recorded = RecordedMenuPopover()
            func representable() -> ReaderMenuAnchor {
                var anchor = ReaderMenuAnchor(
                    open: Binding(get: { open }, set: { open = $0 }),
                    title: "论文选项", items: { items }, width: 174, point: clickPoint)
                anchor.makePopover = { recorded }
                return anchor
            }
            func source() -> some View {
                Color.clear.frame(width: buttonSize.width, height: buttonSize.height)
                    .background { representable() }
                    .frame(width: 210, height: 320, alignment: clickPoint == nil ? .topTrailing : .bottomTrailing)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 210, height: 320), styleMask: .borderless, backing: .buffered,
                defer: false)
            let host = NSHostingView(rootView: source())
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            open = true
            host.rootView = source()
            let deadline = ContinuousClock.now + .seconds(2)
            while recorded.anchors.isEmpty && ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let trigger = try #require(recorded.anchors.first)
            #expect(trigger.bounds.size == buttonSize)
            let expected = clickPoint.map { CGRect(origin: $0, size: .init(width: 1, height: 1)) } ?? trigger.bounds
            #expect(recorded.rectangles == [expected])
            #expect(recorded.edges == [clickPoint == nil ? .maxY : .minY])
            let panel = try #require(recorded.contentViewController)
            #expect(panel.preferredContentSize.width == 174)
            #expect((90...125).contains(panel.preferredContentSize.height))
            #expect(!window.isVisible)
        }
    }

    @Test @MainActor func longShelfPickerScrollsItsLastDestinationIntoReach() async throws {
        let items = (0..<40).map { index in ReaderMenuItem.action("书架 \(index)") {} }
        let panel = ReaderMenuPanel(title: "移动到书架", items: items, width: 174, dismiss: {})
        let host = NSHostingView(rootView: panel)
        let size = host.fittingSize
        #expect(size.width == 174 && (320...380).contains(size.height))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func scrollView(in view: NSView) -> NSScrollView? {
            view as? NSScrollView ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while scrollView(in: host) == nil, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try #require(scrollView(in: host))
        let rows = try #require(scroll.documentView)
        #expect(rows.bounds.height > scroll.documentVisibleRect.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: rows.bounds.height - scroll.documentVisibleRect.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY >= rows.bounds.maxY - 1)
        #expect(!window.isVisible)
    }
#endif
