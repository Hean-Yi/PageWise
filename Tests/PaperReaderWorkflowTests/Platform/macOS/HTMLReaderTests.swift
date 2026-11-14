#if os(macOS)
    import AppKit
    import Foundation
    @testable import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func htmlReaderKeepsDOMSelectionAndAnchorsWhenAppendingAndReopensSavedHighlights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        var first = TextBlock(sourcePage: 0, text: "Precise evidence remains selectable.")
        let svg =
            "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><rect width='200' height='100' fill='#7aaba0'/><text x='12' y='50'>KEEP_LABEL</text></svg>"
        let uri = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        first.richContent = RichContent(
            html:
                "<p>Precise evidence remains selectable.</p><math><msub><mi>x</mi><mi>i</mi></msub></math><img src='\(uri)' width='200' height='100'>",
            translationInput: first.text, mathematics: [:], mathDescriptions: [:])
        var second = TextBlock(sourcePage: 1, text: "Later content does not replace earlier evidence.")
        second.richContent = RichContent(
            html: "<p>Later evidence.</p><img src='\(uri)' width='200' height='100'>", translationInput: second.text,
            mathematics: [:], mathDescriptions: [:])
        var paper = Paper(
            title: "HTML fixture", digest: "local", originalPath: "unused.pdf", pageCount: 2,
            blocks: [first, second], warnings: [], canReflow: true)
        let store = HTMLReadingStore()
        paper.htmlReading = try await store.append(
            [BilingualBlock(block: first, translation: "精确证据。")], to: nil, paper: paper, root: root)
        paper.translatedBlockCount = 1
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await waitForHTML(web, count: 1)
        let imageReady =
            try await web.callAsyncJavaScript(
                "const img=document.images[0]; if(!img.complete) await new Promise((resolve,reject)=>{img.onload=resolve;img.onerror=reject}); return img.naturalWidth === 200 && document.querySelector('math').getBoundingClientRect().height > 0",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(imageReady == true)
        _ = try await web.callAsyncJavaScript(
            "window.originalSection=document.querySelector('section'); const r=document.createRange();r.setStart(originalSection.querySelector('p').firstChild,0);r.setEnd(originalSection.querySelector('p').firstChild,16); const s=getSelection();s.removeAllRanges();s.addRange(r);",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<100 {
            if model.selectionText == "Precise evidence" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selectionText == "Precise evidence")
        #expect(model.selectionHTMLRange == [0, 16])
        model.highlightSelection()
        coordinator.update(web)
        let next = try await store.append(
            [BilingualBlock(block: second, translation: nil)], to: paper.htmlReading, paper: paper, root: root)
        paper.htmlReading = next
        paper.translatedBlockCount = 2
        #expect(await model.save(publishingReflow: paper))
        try HTMLReadingStore.cleanup(root: root, paper: paper)
        let backing = try #require(web.url)
        #expect(FileManager.default.fileExists(atPath: backing.path))
        coordinator.update(web)
        try await waitForHTML(web, count: 2)
        let appendedImage =
            try await web.callAsyncJavaScript(
                "const img=document.images[1];img.loading='eager';if(!img.complete) await new Promise((resolve)=>{img.onload=resolve;img.onerror=resolve;setTimeout(resolve,2000)});return {width:img.naturalWidth,src:img.src,base:document.baseURI}",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(appendedImage?["width"] as? Int == 200, "\(appendedImage ?? [:])")
        let isolated =
            try await web.callAsyncJavaScript(
                "window.paperReader.append(html, 'another-paper'); return document.querySelectorAll('#reader > section').length",
                arguments: ["html": "<section id='block-wrong' data-key='wrong'>Wrong paper</section>"], in: nil,
                contentWorld: .defaultClient) as? Int
        #expect(isolated == 2)
        let preserved =
            try await web.callAsyncJavaScript(
                "return originalSection===document.querySelector('section') && getSelection().toString()==='Precise evidence'",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(preserved == true)
        let highlighted =
            try await web.callAsyncJavaScript(
                "return CSS.highlights.get('saved').size", arguments: [:], in: nil, contentWorld: .defaultClient)
            as? Int
        #expect(highlighted == 1)
        model.navigateToPage(1)
        coordinator.update(web)
        model.toggleBookmark()
        await model.flushReadingPosition()
        let reopened = try ReaderModel(root: root)
        await reopened.load()
        reopened.select(paper.id)
        #expect(reopened.usesHTMLReading)
        #expect(reopened.state.highlights.first?.textRange == [0, 16])
        #expect(reopened.paper?.readingPages.map(\.id) == [first.id, second.id])
        #expect(!reopened.currentBookmarks.isEmpty)
        model.select(nil)
        reopened.select(nil)
        coordinator.stop(web)
        #expect(!FileManager.default.fileExists(atPath: backing.path))
        let documents = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(next.relativePath).deletingLastPathComponent().path
        ).filter { $0.hasSuffix(".html") }
        #expect(documents.count == 1)
    }

    @Test @MainActor func fillingPendingTranslationKeepsSourceDOMAndCompletedGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let blocks = [
            TextBlock(sourcePage: 0, text: "Completed original"), TextBlock(sourcePage: 0, text: "Pending original"),
        ]
        var paper = Paper(
            title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1, blocks: blocks, warnings: [],
            canReflow: true)
        let store = HTMLReadingStore()
        paper.htmlReading = try await store.prepareOriginal(paper: paper, root: root)
        paper.htmlReading = try await store.append(
            [BilingualBlock(block: blocks[0], translation: "完成的译文")], to: paper.htmlReading, paper: paper, root: root)
        paper.translatedBlockCount = 1
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await waitForHTML(web, count: 2)
        _ = try await web.callAsyncJavaScript(
            "window.first = document.querySelector('section'); window.source=document.querySelectorAll('section')[1].querySelector('p');window.height=first.getBoundingClientRect().height;",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        model.translationDraft = TranslationDraft(paperID: paper.id, block: blocks[1], text: "逐字")
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript(
                "return document.querySelector('.pending').textContent.includes('逐字')", arguments: [:], in: nil,
                contentWorld: .defaultClient)) as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let streaming =
            try await web.callAsyncJavaScript(
                "return document.querySelector('.pending').textContent.includes('逐字') && !document.getElementById('translation-draft')",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(streaming == true)
        paper.htmlReading = try await store.append(
            [BilingualBlock(block: blocks[1], translation: "逐字出现的最终译文")], to: paper.htmlReading, paper: paper,
            root: root)
        paper.translatedBlockCount = 2
        #expect(await model.save(publishingReflow: paper))
        model.translationDraft = nil
        coordinator.update(web)
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript(
                "return document.querySelectorAll('.pending').length", arguments: [:], in: nil,
                contentWorld: .defaultClient)) as? Int == 0
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stable =
            try await web.callAsyncJavaScript(
                "return first===document.querySelector('section') && source===document.querySelectorAll('section')[1].querySelector('p') && height===first.getBoundingClientRect().height && document.querySelectorAll('.pending').length===0 && document.body.textContent.includes('逐字出现的最终译文')",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(stable == true)
        model.select(nil)
    }

    @MainActor private func waitForHTML(_ web: WKWebView, count: Int) async throws {
        for _ in 0..<300 {
            let value = try? await web.callAsyncJavaScript(
                "return document.querySelectorAll('#reader > section').length", arguments: [:], in: nil,
                contentWorld: .defaultClient)
            if value as? Int == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReaderError.message("HTML reader did not become ready")
    }
#endif
