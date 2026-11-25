#if os(macOS)
    import AppKit
    import PaperReaderKit
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
                width: 208, location: nil)
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
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        let items: [ReaderMenuItem] = [
            .submenu("移动到书架", icon: .library, items: [.action("未分类") {}]),
            .submenu("阅读状态", icon: .read, items: [.action("已读") {}]),
            .divider, .action("删除论文…", icon: .delete, destructive: true) {},
        ]
        for (index, type) in [nil, NSEvent.EventType.rightMouseDown, .rightMouseDown].enumerated() {
            let window = NSWindow(
                contentRect: NSRect(x: 70 + 45 * index, y: 120 + 50 * index, width: 420, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let content: NSView = index.isMultiple(of: 2) ? NSView() : FlippedView()
            window.contentView = content
            defer { window.contentView = nil }
            let section = FlippedView(frame: NSRect(x: 60, y: 47, width: 320, height: 260))
            content.addSubview(section)
            let position = NSRect(x: 48, y: 70 + index * 40, width: 30, height: 30)
            let receiver = ReaderSecondaryClick.Target(frame: position)
            section.addSubview(receiver)
            var open = false
            var location: ReaderMenuLocation?
            let recorded = RecordedMenuPopover()
            func source() -> some View {
                var anchor = ReaderMenuAnchor(
                    open: Binding(get: { open }, set: { open = $0 }),
                    title: "论文选项", items: { items }, width: 174, location: location)
                anchor.makePopover = { recorded }
                return Color.clear.frame(width: 30, height: 30).background { anchor }
            }
            let host = NSHostingView(rootView: source())
            // The pointer's receiver can have a different origin from the transient SwiftUI background anchor.
            let rearranged = index == 2
            host.frame = rearranged ? position.offsetBy(dx: 80, dy: 24) : position
            section.addSubview(host)
            host.layoutSubtreeIfNeeded()
            let trigger: NSRect
            if let type {
                let hit = receiver.convert(NSPoint(x: 8, y: 20), to: nil)
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: hit, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                receiver.action = { location = $0 }
                receiver.rightMouseDown(with: event)
                try #require(location != nil)
                trigger = NSRect(origin: hit, size: NSSize(width: 1, height: 1))
            } else {
                trigger = receiver.convert(receiver.bounds, to: nil)
            }
            open = true
            host.rootView = source()
            let deadline = ContinuousClock.now + .seconds(2)
            while recorded.anchors.isEmpty && ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let positioningView = try #require(recorded.anchors.first)
            let relativeToView = try #require(recorded.rectangles.first)
            #expect((positioningView === content) == rearranged)
            #expect(
                window.convertToScreen(positioningView.convert(relativeToView, to: nil))
                    == window.convertToScreen(trigger))
            let panel = try #require(recorded.contentViewController)
            #expect(panel.preferredContentSize.width == 174)
            #expect((90...125).contains(panel.preferredContentSize.height))
            let below = trigger.minY - window.contentLayoutRect.minY
            let above = window.contentLayoutRect.maxY - trigger.maxY
            let showBelow = below >= panel.preferredContentSize.height + 14 || below >= above
            #expect(recorded.edges == [showBelow == positioningView.isFlipped ? .maxY : .minY])
            #expect(!window.isVisible)
        }
    }

    @Test @MainActor func transientMenuWindowTouchesItsTriggerAtDifferentScreenPositions() async throws {
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        final class LayoutPopover: NSPopover {
            override func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
                animates = false
                super.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
                contentViewController?.view.window?.alphaValue = 0
            }
        }

        let screen = try #require(NSScreen.main).visibleFrame
        for fromButton in [false, true] {
            let window = NSWindow(
                contentRect: NSRect(
                    x: screen.midX - (fromButton ? 220 : 100), y: screen.midY - (fromButton ? 120 : 60),
                    width: 340, height: 280), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.alphaValue = 0
            let content: NSView = fromButton ? NSView() : FlippedView()
            window.contentView = content
            let group = FlippedView(frame: NSRect(x: 47, y: 44, width: 240, height: 195))
            content.addSubview(group)
            let button = NSButton(
                frame: NSRect(x: fromButton ? 42 : 112, y: fromButton ? 135 : 25, width: 32, height: 32))
            button.title = "…"
            group.addSubview(button)

            let popover = LayoutPopover()
            defer {
                popover.close()
                window.orderOut(nil)
                window.contentView = nil
            }
            var open = false
            var location: ReaderMenuLocation?
            var showsAnchor = true
            func source() -> some View {
                var anchor = ReaderMenuAnchor(
                    open: Binding(get: { open }, set: { open = $0 }), title: "选项",
                    items: { [.action("移动到书架") {}, .action("阅读状态") {}] }, width: 174, location: location)
                anchor.makePopover = { popover }
                return Color.clear.frame(width: 32, height: 32).background { if showsAnchor { anchor } }
            }
            let host = NSHostingView(rootView: source())
            // A mouse event must still attach to its button when the backing view has been rearranged.
            host.frame = fromButton ? button.frame : button.frame.offsetBy(dx: -88, dy: 64)
            group.addSubview(host)
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            let sourceRect = button.convert(button.bounds, to: nil)
            if !fromButton {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: .rightMouseDown, location: NSPoint(x: sourceRect.midX, y: sourceRect.midY),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                location = ReaderMenuLocation(event: event)
            }
            open = true
            host.rootView = source()
            let deadline = ContinuousClock.now + .seconds(2)
            while popover.contentViewController?.view.window == nil && ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let popupWindow = try #require(popover.contentViewController?.view.window)
            let firstFrame = popupWindow.frame
            // An unmeasured hosting controller briefly shows at 320 × 320 and then shrinks away from its arrow.
            #expect(firstFrame.width < 230 && firstFrame.height < 145)
            try await Task.sleep(for: .milliseconds(120))
            let menu = popupWindow.frame
            #expect(abs(menu.width - firstFrame.width) <= 1 && abs(menu.height - firstFrame.height) <= 1)
            let triggerOnScreen = window.convertToScreen(sourceRect)
            let attachment =
                fromButton
                ? triggerOnScreen : CGRect(x: triggerOnScreen.midX, y: triggerOnScreen.midY, width: 1, height: 1)
            let gap = min(abs(menu.maxY - attachment.minY), abs(menu.minY - attachment.maxY))
            #expect(popover.isShown && menu.width >= 174)
            #expect(abs(menu.midX - attachment.midX) < 14, "menu \(menu), trigger \(attachment)")
            #expect(gap < 14, "menu \(menu), trigger \(attachment)")

            if fromButton {
                button.frame = button.frame.offsetBy(dx: 54, dy: -24)
                host.frame = button.frame
                host.rootView = source()
                let moved = window.convertToScreen(button.convert(button.bounds, to: nil))
                let moveDeadline = ContinuousClock.now + .seconds(2)
                while abs(popupWindow.frame.midX - moved.midX) >= 14 && ContinuousClock.now < moveDeadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(abs(popupWindow.frame.midX - moved.midX) < 14)
                #expect(min(abs(popupWindow.frame.maxY - moved.minY), abs(popupWindow.frame.minY - moved.maxY)) < 14)
            }

            showsAnchor = false
            host.rootView = source()
            let closeDeadline = ContinuousClock.now + .seconds(2)
            while popover.isShown && ContinuousClock.now < closeDeadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!popover.isShown)
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

    @Test @MainActor func restingCoverExposesItsOptionsBeforeAnyHover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        let paper = Paper(
            title: "Menu fixture", digest: "cover-options", originalPath: "unused.pdf", pageCount: 1, blocks: [],
            warnings: [], canReflow: false)
        let host = NSHostingView(
            rootView: BookshelfItem(
                model: model, paper: paper, recordFrame: { _ in }, previewed: false, showPreview: { _ in },
                releasePreview: { false }, hoverCover: { _ in }
            ).frame(width: 168).environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func options(in element: AnyObject) -> AnyObject? {
            if element.accessibilityIdentifier?() == "paper-options-" + paper.id.uuidString { return element }
            for child in element.accessibilityChildren?() ?? [] {
                if let button = options(in: child as AnyObject) { return button }
            }
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while options(in: host) == nil && ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let button = try #require(options(in: host))
        #expect(button.accessibilityLabel?() == paper.title + "的选项")
        let frame = try #require(button.accessibilityFrame?())
        #expect(frame.width >= 30 && frame.height >= 30)
        #expect(!window.isVisible)
    }
#endif
