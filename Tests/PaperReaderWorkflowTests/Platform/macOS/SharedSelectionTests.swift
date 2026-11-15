#if os(macOS)
    import Foundation
    @testable import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func sharedObjectsRemainSelectableFromEitherLanguageWithoutForeignCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let first = TextBlock(sourcePage: 0, text: "First original paragraph.")
        var shared = TextBlock(sourcePage: 0, text: "English caption describing the shared chart.")
        let svg =
            "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='40'><rect width='80' height='40' fill='blue'/></svg>"
        let uri = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        shared.richContent = RichContent(
            html:
                "<table><tr><td></td></tr></table><figure><img src='\(uri)' width='80' height='40'><figcaption>English caption describing the shared chart.</figcaption></figure><table><tr><th>Metric</th><td>0.9</td></tr></table><math display='block'><mi>x</mi><mo>=</mo><mn>2</mn></math>",
            translationInput: shared.text, mathematics: [:], mathDescriptions: [:])
        var last = TextBlock(sourcePage: 1, text: "Last original uses a formula.")
        let math = "<math><mi>y</mi></math>"
        last.richContent = RichContent(
            html: "<p>Last original uses \(math) in context.</p>",
            translationInput: "Last original uses ⟦M0⟧ in context.",
            mathematics: ["⟦M0⟧": math], mathDescriptions: ["⟦M0⟧": "y"])
        var paper = Paper(
            title: "Shared selection fixture", digest: "shared", originalPath: "unused.pdf", pageCount: 2,
            blocks: [first, shared, last], warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            [
                BilingualBlock(block: first, translation: "第一段中文。"),
                BilingualBlock(block: shared, translation: "共享图表的中文图注。"),
                BilingualBlock(block: last, translation: "末段中文使用 ⟦M0⟧ 公式。"),
            ], to: nil, paper: paper, root: root)
        paper.translatedBlockCount = 3
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        for _ in 0..<200 {
            if (try? await sharedJS(web, "return !!window.paperSelection")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await sharedJS(
            web,
            "window.blocks=[...document.querySelectorAll('section')];window.firstNode=blocks[0].querySelector('p');window.firstHTML=blocks[0].innerHTML;"
        )
        for target in [".translation", "p"] {
            _ = try await sharedJS(
                web,
                "const a=blocks[0].querySelector('\(target)').firstChild;const b=blocks[2].querySelector('\(target)');getSelection().setBaseAndExtent(a,0,b,b.childNodes.length);"
            )
            try await waitForSharedSelection(model, contains: target == "p" ? "First original" : "第一段中文")
            #expect(model.htmlSelection.filter { $0.target.hasPrefix("object:") }.count == 4)
            #expect(model.selectionText.contains("[图片 1]"))
            #expect(model.selectionText.contains("[表格] Metric\t0.9"))
            #expect(model.selectionText.contains("[公式] x=2"))
            #expect(model.selectionText.components(separatedBy: "[公式] y").count == 2)
            if target == "p" {
                #expect(!model.selectionText.contains("中文"))
                #expect(model.selectionText.contains("English caption"))
            } else {
                #expect(!model.selectionText.contains("original"))
                #expect(!model.selectionText.contains("English caption"))
                #expect(model.selectionText.contains("中文图注"))
                model.highlightSelection()
                #expect(model.state.highlights.allSatisfy { $0.htmlTarget != "source" })
            }
            #expect(
                try await sharedJS(
                    web,
                    "const data=new DataTransfer();document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:data,cancelable:true}));return data.getData('text/plain')"
                ) as? String == model.selectionText)
        }
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await sharedJS(web, "return document.querySelectorAll('[data-reader-saved]').length")) as? Int == 4
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await sharedJS(web, "return document.querySelectorAll('[data-reader-saved]').length") as? Int == 4)
        #expect(
            try await sharedJS(
                web, "return firstNode===blocks[0].querySelector('p') && firstHTML===blocks[0].innerHTML") as? Bool
                == true)
        // The same action used by the image viewer selects an image without adjacent English text.
        _ = try await sharedJS(web, "window.paperSelection.selectObject(document.images[0]);")
        try await waitForSharedSelection(model, contains: "[图片 1]")
        #expect(model.htmlSelection.count == 1)
        #expect(model.htmlSelection.first?.pageKey == shared.id.uuidString)
        #expect(model.selectionText == "[图片 1]")
        await model.flushReadingPosition()
        let reopened = try ReaderModel(root: root)
        await reopened.load()
        #expect(reopened.state.highlights.filter { $0.htmlTarget?.hasPrefix("object:") == true }.count == 4)
        // Restore both object outlines and independent Chinese ranges in a fresh WebView.
        model.select(nil)
        reopened.select(paper.id)
        let restoredCoordinator = HTMLCoordinator(model: reopened)
        let restoredWeb = restoredCoordinator.makeView()
        restoredCoordinator.update(restoredWeb)
        defer { restoredCoordinator.stop(restoredWeb) }
        for _ in 0..<200 {
            if (try? await sharedJS(restoredWeb, "return document.querySelectorAll('[data-reader-saved]').length"))
                as? Int == 4
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            try await sharedJS(restoredWeb, "return document.querySelectorAll('[data-reader-saved]').length") as? Int
                == 4)
        #expect(
            try await sharedJS(
                restoredWeb,
                "return [...CSS.highlights.get('saved')].every(r=>!!r.startContainer.parentElement.closest('.translation'))"
            ) as? Bool == true)
        reopened.select(nil)
    }

    @MainActor private func sharedJS(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    @MainActor private func waitForSharedSelection(_ model: ReaderModel, contains text: String) async throws {
        for _ in 0..<100 {
            if model.selectionText.contains(text) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Selection not delivered: \(model.selectionText)")
    }
#endif
