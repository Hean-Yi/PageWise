#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import PaperReaderUI

    /// Exercise the real representable and menu button without ordering an AppKit popover onto the user's screen.
    @MainActor private final class RecordedMenuPopover: NSPopover {
        var anchors: [NSView] = []
        var closes = 0

        override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
            anchors.append(positioningView)
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
#endif
