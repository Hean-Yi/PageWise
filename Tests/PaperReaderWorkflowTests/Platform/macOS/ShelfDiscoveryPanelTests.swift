#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @Test @MainActor func onlinePanelFollowsTheShelfAndClosesFromItsVisibleButton() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let shelf = try #require(await model.createShelf(name: "Methods"))
        let search = OnlinePaperSearch(reader: model)
        search.open(shelfID: nil)
        let size = CGSize(width: 880, height: 720)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.contentView = nil }
        func workspace(_ shelfID: UUID?) -> some View {
            LibraryWorkspaceView(
                model: model, collection: .constant(.all), selectedShelfID: .constant(shelfID),
                onlineSearch: search, findRequest: 0, openSample: {}
            )
            .frame(width: size.width, height: size.height)
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            while !condition(), ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition())
        }
        let workspaceHost = NSHostingView(rootView: workspace(nil))
        window.contentView = workspaceHost
        workspaceHost.layoutSubtreeIfNeeded()
        workspaceHost.rootView = workspace(shelf)
        try await wait { search.targetShelfID == shelf }
        workspaceHost.rootView = workspace(nil)
        try await wait { search.targetShelfID == nil }

        let host = NSHostingView(
            rootView: SearchView(search: search, targetName: "未分类论文")
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.accessibilityEnabled, true))
        window.contentView = host
        func closeButton(in node: AnyObject) -> AnyObject? {
            if node.accessibilityLabel?() == "关闭在线查找" { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = closeButton(in: child as AnyObject) { return found }
            }
            return nil
        }
        try await wait { closeButton(in: host) != nil }
        let close = try #require(closeButton(in: host))
        let rect = try #require(close.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        let hit = try #require(host.hitTest(host.convert(point, from: nil)))
        func click(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        hit.mouseDown(with: try click(.leftMouseDown))
        hit.mouseUp(with: try click(.leftMouseUp))
        try await wait { !search.isExpanded }
    }
#endif
