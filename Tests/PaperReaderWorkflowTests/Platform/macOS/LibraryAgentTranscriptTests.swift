#if os(macOS)
    import PaperReaderKit
    import SwiftUI
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func libraryTranscriptLoadsRichAnswerOnlyAsItApproachesTheViewport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        let agent = LibraryAgent(reader: reader)
        // With an unloaded library the turn ends locally. Replace its content with a completed fixture.
        agent.send("fixture")
        for _ in 0..<100 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(agent.turns.first?.id)
        agent.updateTurn(id) { turn in
            turn.question = Array(repeating: "A long reader question with explicit line breaks.", count: 200)
                .joined(separator: "\n")
            turn.error = nil
            turn.answer = "## Derivation\n\nThe equation is $x^2$."
        }

        let host = NSHostingView(
            rootView: LibraryAgentView(
                agent: agent, model: reader, draft: .constant(""), openSettings: {}, didNavigate: {}))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 350, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func mountedAnswers() -> Int { descendants(in: host).filter { $0 is WKWebView }.count }
        let scroll = try #require(descendants(in: host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        try #require(document.bounds.height > 2_000)
        #expect(mountedAnswers() == 0)
        for _ in 0..<100 where mountedAnswers() == 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mountedAnswers() == 1)

        // A pending question is a single new scroll target. No reader gesture has occurred.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try #require(scroll.contentView.bounds.maxY < document.bounds.maxY - 500)
        agent.updateTurn(id) {
            $0.clarification = AgentClarification(question: "Which direction?", options: ["Theory", "Experiment"])
        }
        for _ in 0..<100 where document.bounds.maxY - scroll.contentView.bounds.maxY > 40 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.bounds.maxY - scroll.contentView.bounds.maxY < 40)
    }
#endif
