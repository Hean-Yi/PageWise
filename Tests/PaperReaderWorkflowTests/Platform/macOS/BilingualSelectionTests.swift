#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func independentBilingualSelectionFiltersBothLanguagesAndRestoresHighlights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let first = TextBlock(sourcePage: 0, text: "First original evidence with emoji 🧪 and a conclusion.")
        let second = TextBlock(sourcePage: 1, text: "Second original paragraph remains selectable.")
        let third = TextBlock(sourcePage: 1, text: "The model improves accuracy.")
        var paper = Paper(
            title: "Selection fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 2,
            blocks: [first, second, third], warnings: [], canReflow: true)
        let store = HTMLReadingStore()
        paper.htmlReading = try await store.append(
            [
                BilingualBlock(block: first, translation: "首段中文意译。"),
                BilingualBlock(block: second, translation: "第二段的中文翻译。"),
                BilingualBlock(block: third, translation: "第三段译文。"),
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
        let manuallyAnchored = model.htmlSelection.map {
            NoteAnchor(key: $0.pageKey, target: $0.target, text: $0.text, start: $0.start, end: $0.end)
        }
        let evidence = Evidence(id: "S1", title: paper.title, text: model.selectionText, paperID: paper.id)
        let resolved = try await store.noteAnchors(
            for: model.selectionText, evidence: evidence, paperID: paper.id,
            artifact: try #require(paper.htmlReading), root: root, selection: manuallyAnchored)
        #expect(resolved == manuallyAnchored)
        let quoted = try await store.noteAnchors(
            for: "a conclusion.",
            evidence: Evidence(id: "S1", title: paper.title, text: first.text, paperID: paper.id, blockID: first.id),
            paperID: paper.id, artifact: try #require(paper.htmlReading), root: root)
        let anchors = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quoted))
        let paintedText =
            try await web.callAsyncJavaScript(
                "return anchors.flatMap(a => window.paperSelection.rangesFor(a)).map(r=>r.toString()).join('')",
                arguments: ["anchors": anchors], in: nil, contentWorld: .defaultClient) as? String
        #expect(paintedText == "a conclusion.")
        let copied =
            try await js(
                web,
                "const data=new DataTransfer();document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:data,cancelable:true,bubbles:true}));return data.getData('text/plain');"
            ) as? String
        #expect(copied == model.selectionText)
        #expect(
            try await js(
                web,
                """
                const paragraphs=[originalNode,blocks[1].querySelector('p')].map(n=>n.getBoundingClientRect());
                const ink=[...document.querySelectorAll('#reader-selection-backgrounds span')];
                return ink.length>=2 && ink.every(n=>{const r=n.getBoundingClientRect();
                  return paragraphs.some(p=>r.left>=p.left-1 && r.right<=p.right+1 && r.top>=p.top-1 && r.bottom<=p.bottom+1);
                }) && getComputedStyle(document.body,'::selection').backgroundColor==='rgba(0, 0, 0, 0)';
                """) as? Bool == true)
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
        #expect(model.state.highlights.allSatisfy { $0.htmlTarget == "source" && $0.linksTranslation == nil })
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await js(web, "return CSS.highlights.get('saved')?.size")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            try await js(web, "return [...CSS.highlights.get('saved')].map(r=>r.toString()).join('|')") as? String
                == "original evidence with emoji 🧪 and a conclusion.|Second original")
        #expect(
            try await js(
                web, "return originalNode===blocks[0].querySelector('p') && originalHTML===blocks[0].innerHTML")
                as? Bool == true)
        // Chinese quotes retain exactly the selected translation, with no English substitution.
        _ = try await js(
            web, "const n=blocks[1].querySelector('.translation').firstChild;getSelection().setBaseAndExtent(n,1,n,5)")
        try await waitForSelection(model, count: 1, text: "二段的中")
        #expect(model.selectionText == "二段的中")
        model.highlightSelection()
        #expect(model.state.highlights.last?.htmlTarget == "translation")
        // Cross-paragraph Chinese selection skips the intervening English paragraph.
        _ = try await js(
            web,
            "getSelection().setBaseAndExtent(blocks[0].querySelector('.translation').firstChild,1,blocks[1].querySelector('.translation').firstChild,5)"
        )
        try await waitForSelection(model, count: 2, text: "段中文意译。\n\n第二段的中")
        #expect(try await js(web, "return window.paperSelection.copyText()") as? String == model.selectionText)
        _ = try await js(
            web,
            "getSelection().setBaseAndExtent(blocks[1].querySelector('.translation').firstChild,5,blocks[0].querySelector('.translation').firstChild,1)"
        )
        try await waitForSelection(model, count: 2, text: "段中文意译。\n\n第二段的中")
        // Backwards selection follows document order and includes only English.
        _ = try await js(
            web, "getSelection().setBaseAndExtent(blocks[1].querySelector('p').firstChild,15,originalNode.firstChild,6)"
        )
        try await waitForSelection(model, count: 2)
        #expect(model.htmlSelection.first?.text.hasPrefix("original evidence") == true)
        // Incomplete word, incomplete sentence, and sentence ending inside a word.
        for (end, expected) in [(2, "Th"), (18, "The model improves"), (22, "The model improves acc")] {
            _ = try await js(
                web, "const n=blocks[2].querySelector('p').firstChild;getSelection().setBaseAndExtent(n,0,n,\(end))")
            try await waitForSelection(model, count: 1, text: String(third.text.prefix(end)))
            let count = model.state.highlights.count
            model.highlightSelection()
            #expect(model.state.highlights.count == count + (expected.isEmpty ? 0 : 1))
            if !expected.isEmpty { #expect(model.state.highlights.last?.text == expected) }
        }
        // Selecting the middle of a word saves exactly those characters.
        _ = try await js(
            web, "const n=blocks[2].querySelector('p').firstChild;getSelection().setBaseAndExtent(n,5,n,7)")
        try await waitForSelection(model, count: 1, text: "od")
        let count = model.state.highlights.count
        model.highlightSelection()
        #expect(model.state.highlights.count == count + 1)
        #expect(model.state.highlights.last?.text == "od")
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
        #expect(reopened.state.highlights.count == 7)
        #expect(reopened.state.highlights.allSatisfy { $0.htmlTarget != nil && $0.linksTranslation == nil })
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
        _ = try await web.callAsyncJavaScript(
            "window.paperReader.highlights(marks)",
            arguments: [
                "marks": [
                    ["key": first.id.uuidString, "text": "First", "range": [0, 5], "sourceOnly": true] as [String: Any]
                ]
            ], in: nil, contentWorld: .defaultClient)
        #expect(
            try await js(web, "return [...CSS.highlights.get('saved')].map(r=>r.toString()).join('|')") as? String
                == "First|首段中文意译。")
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
