#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func sidebarMarkdownFitsItsContentAndPreservesSelectionWhileStreaming() async throws {
        var height: CGFloat = 0
        var registered: [String] = []
        var clicked: [String] = []
        func canvas(_ text: String) -> AssistantMarkdownCanvas {
            AssistantMarkdownCanvas(
                request: .init(markdown: text, ids: ["S1"]), fontSize: 13, dark: false,
                onHeight: { height = $0 }, onCitations: { registered = $0 }, onCitation: { clicked.append($0) })
        }
        let source = "## Findings\n\nFirst **evidence** [S1]. Formula $x^2$."
        let coordinator = canvas(source).makeCoordinator()
        let view = coordinator.makeView()
        view.frame = CGRect(x: 0, y: 0, width: 210, height: 70)
        defer { coordinator.stop() }
        for _ in 0..<250 where registered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try #require(registered == ["S1"])
        try #require(height > 0)
        let firstHeight = height
        let rendered =
            try await view.callAsyncJavaScript(
                """
                window.heading=document.querySelector('h2');
                const range=document.createRange();range.selectNodeContents(heading);
                getSelection().removeAllRanges();getSelection().addRange(range);
                document.querySelector('a[data-citation]').click();
                return document.querySelector('math').getBoundingClientRect().height > 0;
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(rendered == true)
        for _ in 0..<50 where clicked.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(clicked == ["S1"])

        coordinator.update(canvas(source + "\n\n- item one\n- item two\n- item three"))
        for _ in 0..<250 where height <= firstHeight { try await Task.sleep(for: .milliseconds(20)) }
        #expect(height > firstHeight)
        let preserved =
            try await view.callAsyncJavaScript(
                """
                return heading===document.querySelector('h2') && getSelection().toString()==='Findings'
                  && document.querySelectorAll('li').length===3
                  && document.documentElement.scrollWidth<=document.documentElement.clientWidth;
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(preserved == true)
    }
    @Test @MainActor func plainSidebarHistoryUsesNoWebViewsAndRichSyntaxStaysOnTheCompilerPath() {
        let plain = ["你好，想了解论文的哪一部分？", "The study compares two retrieval methods.", "3 篇已加入书库。"]
        for text in plain { #expect(AssistantAnswerPresentation.usesNativeText(text)) }
        for markup in [
            "## Title", "**bold**", "`x`", " - bullet", "1. ordered", "paragraph\n---", "$x^2$", #"\(x\)"#,
            "[S1]", "before [S", "[label](url)", "<b>bold</b>", "&amp;", "| x |", "~~~", "> 引文", "a\n\nb",
        ] { #expect(!AssistantAnswerPresentation.usesNativeText(markup), "\(markup)") }

        let host = NSHostingView(
            rootView: VStack {
                ForEach(0..<24, id: \.self) { index in AssistantMarkdownText(markdown: plain[index % plain.count]) }
            })
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        host.layoutSubtreeIfNeeded()
        func webViews(in view: NSView) -> Int {
            (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webViews(in: $1) }
        }
        #expect(webViews(in: host) == 0)
        #expect(host.fittingSize.height > 24 * 10)
        let richHost = NSHostingView(rootView: AssistantMarkdownText(markdown: "## 公式\n\n$x^2$"))
        richHost.frame = host.frame
        richHost.layoutSubtreeIfNeeded()
        #expect(webViews(in: richHost) == 1)
    }

    @Test @MainActor func returningToRichAnswerReusesItsWebViewDOMAndWidthSpecificHeight() async throws {
        var height: CGFloat = 0
        var registered: [String] = []
        var clicked: [String] = []
        func row(_ markdown: String, id: String) -> AssistantMarkdownCanvas {
            AssistantMarkdownCanvas(
                request: .init(markdown: markdown, ids: [id]), fontSize: 13, dark: false,
                onHeight: { height = $0 }, onCitations: { registered = $0 }, onCitation: { clicked.append($0) })
        }
        let first = row("## Cached formula\n\n$x^2$ [S11]", id: "S11")
        let original = first.makeCoordinator()
        let view = original.makeView()
        view.frame = CGRect(x: 0, y: 0, width: 230, height: 100)
        for _ in 0..<250 where registered != ["S11"] || height == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(registered == ["S11"] && height > 0)
        _ = try await view.callAsyncJavaScript(
            "window.originalDOM=document.querySelector('math');", arguments: [:],
            in: nil, contentWorld: .defaultClient)
        original.stop()
        let snap = try #require(AssistantPageCache.snapshot(for: first.request))
        #expect(snap.measurement?.fits(width: 230, fontSize: 13) == true)
        #expect(snap.measurement?.fits(width: 190, fontSize: 13) == false)
        #expect(snap.measurement?.fits(width: 230, fontSize: 17) == false)

        height = 0
        registered = []
        let returned = first.makeCoordinator()
        let sameView = returned.makeView()
        #expect(sameView === view)
        for _ in 0..<250 where registered != ["S11"] || height == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(registered == ["S11"] && height == snap.measurement?.height)
        let sameDOM =
            try await sameView.callAsyncJavaScript(
                "return window.originalDOM === document.querySelector('math');",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(sameDOM == true)
        returned.stop()

        let next = row("Only this reference [S12].", id: "S12").makeCoordinator()
        let nextView = next.makeView()
        defer { next.stop() }
        #expect(nextView === view)
        for _ in 0..<250 where registered != ["S12"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(registered == ["S12"])
        let swapped =
            try await nextView.callAsyncJavaScript(
                "document.querySelector('a').click();return document.querySelector('math') === null && !document.body.innerText.includes('S11');",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(swapped == true)
        for _ in 0..<50 where clicked.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(clicked == ["S12"])
    }
#endif
