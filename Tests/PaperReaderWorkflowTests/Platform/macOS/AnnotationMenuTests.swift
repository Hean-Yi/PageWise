#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit
    @testable import PaperReaderUI

    @Test @MainActor func annotationMenuChangesColorsModesAndPartialCoverageWithoutMovingText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let block = TextBlock(sourcePage: 0, text: "Alpha beta gamma delta epsilon.")
        var paper = Paper(
            title: "Annotation menu", digest: "menu", originalPath: "unused.pdf", pageCount: 1,
            blocks: [block], warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            [BilingualBlock(block: block, translation: "甲乙丙丁戊己庚辛")], to: nil, paper: paper, root: root)
        paper.translatedBlockCount = 1
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 620, height: 500)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await menuWait { (try? await menuJS(web, "return !!window.paperAnnotationMenu")) as? Bool == true }
        _ = try await menuJS(
            web,
            "window.p=document.querySelector('section p');window.html=p.outerHTML;window.height=p.getBoundingClientRect().height;getSelection().setBaseAndExtent(p.firstChild,0,p.firstChild,22)"
        )
        try await menuWait { model.selectionText == "Alpha beta gamma delta" }
        try await menuWait {
            (try? await menuJS(web, "return !document.querySelector('#annotation-menu').hidden")) as? Bool == true
        }
        #expect(
            try await menuJS(web, "return document.querySelector('#annotation-menu .remove').hidden") as? Bool == true)
        #expect(
            try await menuJS(web, "return getComputedStyle(document.querySelector('#annotation-menu .remove')).display")
                as? String == "none")
        _ = try await menuJS(web, "document.querySelector('[data-color=yellow]').click()")
        try await menuWait { model.state.highlights.count == 1 }
        coordinator.update(web)
        try await menuWait {
            (try? await menuJS(web, "return !document.querySelector('#annotation-menu .remove').hidden")) as? Bool
                == true
        }
        #expect(try await menuJS(web, "return CSS.highlights.get('reader-selection').size") as? Int == 1)
        _ = try await menuJS(web, "getSelection().setBaseAndExtent(p.firstChild,6,p.firstChild,16)")
        try await menuWait { model.selectionText == "beta gamma" }
        _ = try await menuJS(web, "document.querySelector('[data-color=blue]').click()")
        try await menuWait { model.state.highlights.count == 3 }
        coordinator.update(web)
        try await menuWait {
            (try? await menuJS(web, "return document.querySelector('[data-color=blue]').getAttribute('aria-pressed')"))
                as? String == "true"
        }
        _ = try await menuJS(web, "document.querySelector('[data-mode=underline]').click()")
        try await menuWait { model.state.highlights.contains { $0.text == "beta gamma" && $0.style == .underline } }
        coordinator.update(web)
        try await menuWait {
            (try? await menuJS(web, "return CSS.highlights.get('saved-blue-underline')?.size")) as? Int == 1
        }
        #expect(
            try await menuJS(
                web, "return document.querySelector('#reader-annotation-lines span')?.style.borderBottomStyle")
                as? String == "solid")
        #expect(
            try await menuJS(web, "return [...CSS.highlights.get('reader-selection')].map(r=>r.toString()).join('')")
                as? String == "beta gamma")
        #expect(
            try await menuJS(
                web,
                "return CSS.highlights.get('reader-selection').priority > CSS.highlights.get('saved-blue-underline').priority"
            ) as? Bool == true)
        #expect(try await menuJS(web, "return !getSelection().isCollapsed") as? Bool == true)
        // Mixed new + previously annotated content; outside fragments must keep their old style.
        _ = try await menuJS(web, "getSelection().setBaseAndExtent(p.firstChild,11,p.firstChild,30)")
        try await menuWait { model.selectionText == "gamma delta epsilon" }
        _ = try await menuJS(web, "window.paperAnnotationMenu.show()")
        #expect(
            try await menuJS(web, "return document.querySelector('#annotation-menu .remove').hidden") as? Bool == true)
        _ = try await menuJS(web, "document.querySelector('[data-color=green]').click()")
        try await menuWait {
            model.state.highlights.contains { $0.text == "gamma delta epsilon" && $0.color == .green }
        }
        coordinator.update(web)
        _ = try await menuJS(web, "getSelection().setBaseAndExtent(p.firstChild,17,p.firstChild,22)")
        try await menuWait { model.selectionText == "delta" }
        _ = try await menuJS(
            web, "window.paperAnnotationMenu.show();document.querySelector('#annotation-menu .remove').click()")
        try await menuWait { model.state.highlights.count == 4 }
        #expect(
            model.state.highlights.sorted { $0.textRange![0] < $1.textRange![0] }.map(\.text) == [
                "Alpha ", "beta ", "gamma ", " epsilon",
            ])
        // The bookmark control adds the selection anchor and is idempotent.
        _ = try await menuJS(
            web,
            "document.querySelector('#annotation-menu .bookmark').click();document.querySelector('#annotation-menu .bookmark').click()"
        )
        try await menuWait { model.currentBookmarks.count == 1 }
        #expect(model.currentBookmarks[0].pageKey == block.id.uuidString)
        #expect(
            try await menuJS(
                web,
                "return !!document.querySelector('#annotation-menu .add-note:not([disabled])') && p.outerHTML===html && p.getBoundingClientRect().height===height"
            ) as? Bool == true)
        await model.flushReadingPosition()
        let reopened = try ReaderModel(root: root)
        await reopened.load()
        #expect(reopened.state.highlights == model.state.highlights)
        #expect(reopened.state.bookmarks.count == 1)
        // Editing a legacy paired annotation projects its coordinates; unselected Chinese survives.
        var legacy = Highlight(
            paperID: paper.id, pageKey: block.id.uuidString, pageIndex: 0, text: "Alpha beta gamma", rects: [])
        legacy.textRange = [0, 16]
        legacy.linksTranslation = true
        model.state.highlights = [legacy]
        coordinator.update(web)
        try await menuWait {
            (try? await menuJS(web, "return window.paperSelection.projectedMarks()[0]?.id")) as? String
                == legacy.id.uuidString
        }
        _ = try await menuJS(web, "getSelection().setBaseAndExtent(p.firstChild,6,p.firstChild,10)")
        try await menuWait { model.selectionText == "beta" }
        _ = try await menuJS(
            web, "window.paperAnnotationMenu.show();document.querySelector('[data-color=red]').click()")
        try await menuWait { model.state.highlights.contains { $0.text == "beta" && $0.color == .red } }
        #expect(model.state.highlights.contains { $0.htmlTarget == "translation" && $0.text == "甲乙丙丁戊己庚辛" })
        #expect(
            model.state.highlights.filter { $0.htmlTarget == "source" }.sorted { $0.textRange![0] < $1.textRange![0] }
                .map(\.text) == ["Alpha ", "beta", " gamma"])
        // A menu focus change can collapse WebKit's native selection; the logical selection must survive.
        _ = try await menuJS(
            web,
            "document.querySelector('[data-color=red]').dispatchEvent(new Event('focusin',{bubbles:true}));getSelection().removeAllRanges()"
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.selectionText == "beta")
        #expect(try await menuJS(web, "return CSS.highlights.get('reader-selection').size") as? Int == 1)
        // Clicking elsewhere clears even the preserved logical range.
        _ = try await menuJS(
            web, "p.dispatchEvent(new Event('pointerdown',{bubbles:true}));getSelection().collapse(p.firstChild,0)")
        try await menuWait { model.selectionText.isEmpty }
        #expect(try await menuJS(web, "return CSS.highlights.get('reader-selection').size") as? Int == 0)
        model.select(nil)
    }

    @MainActor private func menuJS(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }
    @MainActor private func menuWait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Annotation menu condition not satisfied")
    }
#endif
