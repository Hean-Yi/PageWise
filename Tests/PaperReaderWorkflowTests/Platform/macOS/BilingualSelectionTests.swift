#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func bilingualCrossParagraphSelectionCopiesOnlySourceAndRestoresPairedHighlights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let first = TextBlock(sourcePage: 0, text: "First original evidence with emoji 🧪 and a conclusion.")
        let second = TextBlock(sourcePage: 1, text: "Second original paragraph remains selectable.")
        let third = TextBlock(sourcePage: 1, text: "Pending original paragraph.")
        var paper = Paper(
            title: "Selection fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 2,
            blocks: [first, second, third], warnings: [], canReflow: true)
        let store = HTMLReadingStore()
        paper.htmlReading = try await store.prepareOriginal(paper: paper, root: root)
        paper.htmlReading = try await store.append(
            [
                BilingualBlock(block: first, translation: "首段中文意译。"),
                BilingualBlock(block: second, translation: "第二段的中文翻译。"),
            ], to: paper.htmlReading, paper: paper, root: root)
        paper.translatedBlockCount = 2
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 620, height: 600)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        for _ in 0..<200 {
            if (try? await js(web, "return !!window.paperSelection")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await js(
            web,
            "window.blocks=[...document.querySelectorAll('section')];window.originalNode=blocks[0].querySelector('p');window.originalHTML=blocks[0].innerHTML;const selection=getSelection();selection.setBaseAndExtent(originalNode.firstChild,6,blocks[1].querySelector('p').firstChild,15);"
        )
        try await waitForSelection(model, count: 2)
        #expect(model.selectionText == "original evidence with emoji 🧪 and a conclusion.\n\nSecond original")
        #expect(model.htmlSelection.map(\.pageKey) == [first.id.uuidString, second.id.uuidString])
        #expect(model.htmlSelection[0].end - model.htmlSelection[0].start == model.htmlSelection[0].text.utf16.count)
        let copied =
            try await js(
                web,
                "const data=new DataTransfer();document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:data,cancelable:true,bubbles:true}));return data.getData('text/plain');"
            ) as? String
        #expect(copied == model.selectionText)
        #expect(
            try await js(
                web,
                "return [...CSS.highlights.get('reader-selection')].every(r=>r.startContainer===r.endContainer && !r.startContainer.parentElement.closest('.translation'))"
            ) as? Bool == true)
        #expect(
            try await js(web, "return getComputedStyle(originalNode,'::selection').backgroundColor") as? String
                == "rgba(0, 0, 0, 0)")
        model.highlightSelection()
        #expect(model.state.highlights.count == 2)
        #expect(model.state.highlights.allSatisfy { $0.linksTranslation == true && !$0.text.contains("中文") })
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await js(web, "return CSS.highlights.get('saved')?.size")) as? Int == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            try await js(web, "return [...CSS.highlights.get('saved')].map(r=>r.toString()).join('|')") as? String
                == "original evidence with emoji 🧪 and a conclusion.|首段中文意译。|Second original|第二段的中文翻译。")
        #expect(
            try await js(
                web, "return originalNode===blocks[0].querySelector('p') && originalHTML===blocks[0].innerHTML")
                as? Bool == true)
        // A Chinese-only selection links to the whole English paragraph, never its duplicate translation.
        _ = try await js(
            web, "const n=blocks[1].querySelector('.translation').firstChild;getSelection().setBaseAndExtent(n,1,n,5)")
        try await waitForSelection(model, count: 1, text: second.text)
        #expect(model.selectionText == second.text)
        // Backwards selection follows document order and includes only English.
        _ = try await js(
            web, "getSelection().setBaseAndExtent(blocks[1].querySelector('p').firstChild,15,originalNode.firstChild,6)"
        )
        try await waitForSelection(model, count: 2)
        #expect(model.htmlSelection.first?.text.hasPrefix("original evidence") == true)
        // Highlighting pending source text picks up its translation when it publishes later.
        _ = try await js(
            web, "const n=blocks[2].querySelector('p').firstChild;getSelection().setBaseAndExtent(n,0,n,7)")
        try await waitForSelection(model, count: 1, text: "Pending")
        model.highlightSelection()
        paper.htmlReading = try await store.append(
            [BilingualBlock(block: third, translation: "后来完成的译文。")], to: paper.htmlReading, paper: paper, root: root)
        paper.translatedBlockCount = 3
        #expect(await model.save(publishingReflow: paper))
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await js(web, "return [...CSS.highlights.get('saved')].some(r=>r.toString().trim()==='后来完成的译文。')"))
                as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            try await js(web, "return [...CSS.highlights.get('saved')].some(r=>r.toString().trim()==='后来完成的译文。')")
                as? Bool
                == true)
        model.selectionText = ""
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await js(web, "return getSelection().isCollapsed")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await js(web, "return getSelection().isCollapsed") as? Bool == true)
        await model.flushReadingPosition()
        let reopened = try ReaderModel(root: root)
        await reopened.load()
        #expect(reopened.state.highlights.count == 3)
        #expect(reopened.state.highlights.allSatisfy { $0.linksTranslation == true })
        // Legacy coordinates keep their old meaning, including a translation-only highlight.
        let legacy = "return blocks[0].textContent.indexOf('首段中文意译。')"
        let start = try #require(try await js(web, legacy) as? Int)
        let legacyMarks: [[String: Any]] = [
            ["key": first.id.uuidString, "text": "首段中文意译。", "range": [start, start + 7]]
        ]
        _ = try await web.callAsyncJavaScript(
            "window.paperReader.highlights(marks)", arguments: ["marks": legacyMarks], in: nil,
            contentWorld: .defaultClient)
        #expect(
            try await js(web, "return [...CSS.highlights.get('saved')].map(r=>r.toString()).join('')") as? String
                == "首段中文意译。")
        model.select(nil)
    }

    @MainActor private func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }
    @MainActor private func waitForSelection(_ model: ReaderModel, count: Int, text: String? = nil) async throws {
        for _ in 0..<100 {
            if model.htmlSelection.count == count, text == nil || model.selectionText == text { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Selection not delivered: \(model.selectionText)")
    }
#endif
