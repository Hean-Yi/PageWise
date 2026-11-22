#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func pdfSentenceLayoutsKeepTheSameRangeWhenAnEarlierTranslationArrives() async throws {
        let sentences = ["a", "b", "c"].map { id in
            PDFSourceSentence(id: id, text: "Repeated line.", pageIndex: 0, rects: [], paragraphID: "p")
        }
        var chosen: String?
        var selection: [String] = []
        func canvas(translations: [String: String], stacked: Bool) -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, stacked: stacked, fontSize: stacked ? 19 : 16,
                activeID: "b", focusedID: "b",
                focusRevision: 1, followsScroll: true, sourceScrollID: nil, sourceScrollRevision: 0,
                pdfSelectedIDs: ["c"],
                onScroll: { _ in }, onSelection: { selection = $0 }, onFocus: { chosen = $0 }, onHover: { _ in })
        }
        let initial = ["b": "中间的重复句。", "c": "中间的重复句。"]
        let first = canvas(translations: initial, stacked: false)
        let coordinator = first.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        for _ in 0..<160 {
            if let ready = try? await web.callAsyncJavaScript(
                "return document.querySelectorAll('.pair').length===2",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool, ready
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let onlyChinese =
            try await web.callAsyncJavaScript(
                """
                const pair=document.querySelector('#b');
                window.original=pair;
                const range=document.createRange();
                range.setStart(pair.lastChild.firstChild,0); range.setEnd(pair.lastChild.firstChild,2);
                const s=getSelection(); s.removeAllRanges(); s.addRange(range);
                return getComputedStyle(pair.firstChild).display==='none';
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(onlyChinese == true)

        var completed = initial
        completed["a"] = "作为文本显示 <img src='x'>。"
        coordinator.update(canvas(translations: completed, stacked: true), view: web)
        let preserved =
            try await web.callAsyncJavaScript(
                """
                const p=document.querySelector('p'), b=document.getElementById('b');
                return p.children.length===3 && [...p.children].map(s=>s.id).join('')==='abc'
                  && document.images.length===0 && document.body.textContent.includes("<img src='x'>")
                  && b===window.original && getSelection().toString()==='中间'
                  && getComputedStyle(b.firstChild).display==='block' && getComputedStyle(b.lastChild).fontSize==='19px'
                  && b.classList.contains('active');
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(preserved == true)
        _ = try await web.callAsyncJavaScript(
            """
            const b=document.getElementById('b'), c=document.getElementById('c');
            const range=document.createRange();range.setStart(b.lastChild.firstChild,1);range.setEnd(c.lastChild.firstChild,2);
            const s=getSelection();s.removeAllRanges(); s.addRange(range);
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<60 where selection != ["b", "c"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selection == ["b", "c"])
        let copied =
            try await web.callAsyncJavaScript(
                """
                const clipboard = new DataTransfer();
                document.dispatchEvent(new ClipboardEvent('copy', {clipboardData: clipboard, cancelable: true}));
                return clipboard.getData('text/plain');
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        #expect(copied == "间的重复句。中间")
        _ = try await web.callAsyncJavaScript(
            "getSelection().removeAllRanges();document.getElementById('c').click();",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<60 where chosen == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chosen == "c")
    }
    @Test @MainActor func pdfSentenceScrollFollowsUserInputWithoutEchoingProgrammaticJumps() async throws {
        let sentences = (0..<24).map { index in
            PDFSourceSentence(
                id: "s\(index)", text: "A short sentence.", pageIndex: 0, rects: [], paragraphID: "p\(index)")
        }
        let translations = Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, "这是一段用来验证滚动定位的译文。") })
        var movements: [String] = []
        func canvas(sourceID: String?, revision: Int) -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, stacked: false, fontSize: 16, activeID: nil,
                focusedID: nil,
                focusRevision: 0, followsScroll: true, sourceScrollID: sourceID, sourceScrollRevision: revision,
                pdfSelectedIDs: [], onScroll: { movements.append($0) }, onSelection: { _ in },
                onFocus: { _ in }, onHover: { _ in })
        }
        let first = canvas(sourceID: nil, revision: 0)
        let coordinator = first.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 440, height: 160)
        for _ in 0..<160 {
            if let ready = try? await web.callAsyncJavaScript(
                "return document.querySelectorAll('.pair').length===24",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool, ready
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.callAsyncJavaScript(
            """
            document.dispatchEvent(new WheelEvent('wheel'));
            document.getElementById('s8').scrollIntoView({block:'start'});
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        for _ in 0..<120 where movements.isEmpty { try await Task.sleep(for: .milliseconds(15)) }
        #expect(!movements.isEmpty)
        let prior = movements
        coordinator.update(canvas(sourceID: "s20", revision: 1), view: web)
        let visible =
            try await web.callAsyncJavaScript(
                """
                const b=document.getElementById('s20').getBoundingClientRect();return b.top>=0 && b.bottom<=innerHeight;
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(visible == true)
        try await Task.sleep(for: .milliseconds(160))
        #expect(movements == prior)
    }
#endif
