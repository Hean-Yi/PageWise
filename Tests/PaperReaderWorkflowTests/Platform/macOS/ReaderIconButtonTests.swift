#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @MainActor private final class IconButtonRecorder {
        var presses = 0
        var interactions: [ReaderIconInteraction] = []
        var reduceMotion = false
    }

    private struct IconProbeLabel: View {
        let recorder: IconButtonRecorder
        @Environment(\.readerIconInteraction) private var interaction
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Text("图标操作")
                .onChange(of: interaction, initial: true) { _, interaction in
                    recorder.reduceMotion = reduceMotion
                    recorder.interactions.append(interaction)
                }
        }
    }

    @Test @MainActor func iconButtonActivatesOnceAndItsInkReturnsToRest() async throws {
        let recorder = IconButtonRecorder()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 100), styleMask: .borderless, backing: .buffered,
            defer: false)
        let control = Button {
            recorder.presses += 1
        } label: {
            IconProbeLabel(recorder: recorder)
        }
        let host = NSHostingView(
            rootView: VStack {
                control.readerIconButtonStyle(.plain).accessibilityLabel("打开笔记")
                control.readerIconButtonStyle(.bordered).disabled(true).accessibilityLabel("停用")
            }
            .environment(\.accessibilityEnabled, true))
        window.contentView = host
        defer { window.contentView = nil }

        func find(_ label: String, in node: AnyObject) -> AnyObject? {
            if node.accessibilityLabel?() == label { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = find(label, in: child as AnyObject) { return found }
            }
            return nil
        }
        func wait(_ description: String, until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !predicate(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(predicate(), "\(description), events \(recorder.interactions), actions \(recorder.presses)")
        }

        try await wait("host loaded") { find("打开笔记", in: host) != nil && !recorder.interactions.isEmpty }
        let disabled = try #require(find("停用", in: host))
        #expect(disabled.isAccessibilityEnabled?() == false)
        _ = disabled.accessibilityPerformPress?()
        #expect(recorder.presses == 0)

        let enabled = try #require(find("打开笔记", in: host))
        #expect(enabled.accessibilityPerformPress?() == true)
        try await wait("triggered") { recorder.presses == 1 }
        let bounds = try #require(enabled.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: CGPoint(x: bounds.midX, y: bounds.midY))
        let hit = try #require(host.hitTest(host.convert(point, from: nil)))
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        hit.mouseDown(with: try mouse(.leftMouseDown))
        hit.mouseUp(with: try mouse(.leftMouseUp))
        try await wait("mouse activated") { recorder.presses == 2 }
        if !recorder.reduceMotion {
            try await wait("ink settled") {
                recorder.interactions.contains(.pressed) && recorder.interactions.last == .idle
            }
        } else {
            #expect(!recorder.interactions.contains(.pressed))
        }
        #expect(recorder.presses == 2)
    }
#endif
