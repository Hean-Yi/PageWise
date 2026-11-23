#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func pdfReflowNotesUnderlineOnlyAnchoredCharactersAndOpenTheirEditor() async throws {
        let sentence = PDFSourceSentence(
            id: "s", text: "word then word.", pageIndex: 0, rects: [], paragraphID: "p",
            characterRanges: [NSRange(location: 30, length: 15)])
        let id = UUID()
        let anchor = NoteAnchor(key: "original-0", target: "pdf", text: "word", start: 40, end: 44)
        var opened: UUID?
        var canvas = PDFSentenceTextCanvas(
            sentences: [sentence], translations: ["s": "对照"], layout: .paragraph, fontSize: 18, focusedID: nil,
            focusRevision: 0, followsScroll: false, sourceScrollID: nil, sourceScrollRevision: 0, pdfSelectedIDs: [],
            onScroll: { _ in }, onSelection: { _ in }, onFocus: { _ in },
            inlineNotes: [.init(id: id, anchors: [anchor], color: nil)], onOpenNote: { opened = $0 })
        let coordinator = canvas.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        for _ in 0..<200 {
            let verified =
                try? await web.callAsyncJavaScript(
                    """
                    const button=document.querySelector('.sentence-note'), ink=CSS.highlights?.get('pdf-reading-notes');
                    if (!button || !ink || ink.size!==1) return false;
                    const [range]=ink;
                    if (range.startOffset!==10 || range.toString()!=='word') return false;
                    button.click();return true;
                    """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
            if verified == true { break }
            try await Task.sleep(for: .milliseconds(35))
        }
        for _ in 0..<50 where opened == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(opened == id)
        let manual = UUID()
        let shorter = NoteAnchor(key: "original-0", target: "pdf", text: "wo", start: 40, end: 42)
        canvas.inlineNotes = [
            .init(id: manual, anchors: [shorter], color: nil), .init(id: id, anchors: [anchor], color: .blue),
        ]
        coordinator.update(canvas, view: web)
        for (index, expected) in [(10, manual), (13, id)] {
            opened = nil
            let sent =
                try await web.callAsyncJavaScript(
                    """
                    const node=document.querySelector('.en'), range=document.createRange();
                    range.setStart(node.firstChild,index);range.setEnd(node.firstChild,index+1);
                    const box=range.getBoundingClientRect();
                    if (!box.width || document.querySelector('.sentence-note').dataset.readingNote!==manual) return false;
                    node.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,
                      clientX:box.x+box.width/2,clientY:box.y+box.height/2}));return true;
                    """, arguments: ["index": index, "manual": manual.uuidString], in: nil, contentWorld: .defaultClient
                ) as? Bool
            #expect(sent == true)
            for _ in 0..<50 where opened == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(opened == expected)
        }
        canvas.inlineNotes = []
        coordinator.update(canvas, view: web)
        let cleared =
            try await web.callAsyncJavaScript(
                "return !document.querySelector('.sentence-note') && CSS.highlights.get('pdf-reading-notes').size===0",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        #expect(cleared == true)
    }

    @Test @MainActor func pdfOriginalBylineAndBibliographyCanBeSelectedAcrossEnglishProse() async throws {
        let sentence = PDFSourceSentence(id: "s", text: "Body sentence.", pageIndex: 0, rects: [], paragraphID: "p")
        let byline = PDFReadingIllustration(
            id: "author", label: "作者与机构", pageIndex: 0, sourceBounds: .zero, insertBeforeSentenceID: "s",
            imagePNG: nil, originalText: .init(kind: .byline, paragraphs: ["Mira Ellis\nAlpine Institute"]))
        let references = PDFReadingIllustration(
            id: "refs", label: "References", pageIndex: 0, sourceBounds: .zero, insertBeforeSentenceID: nil,
            imagePNG: nil, originalText: .init(kind: .references, paragraphs: ["[1] A < B.", "[2] Second title."]))
        let canvas = PDFSentenceTextCanvas(
            sentences: [sentence], translations: ["s": "正文。"], layout: .paragraph, fontSize: 18,
            focusedID: nil, focusRevision: 0, followsScroll: false, sourceScrollID: nil,
            sourceScrollRevision: 0, pdfSelectedIDs: [], onScroll: { _ in }, onSelection: { _ in }, onFocus: { _ in },
            illustrations: [byline, references])
        let coordinator = canvas.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<160 {
            if (try? await evaluate("return !!document.querySelector('.references')")) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let valid = try await evaluate(
            """
            const nodes=[...document.querySelector('main').children];
            const author=nodes[0].querySelector('.source-line'),refs=nodes[2];
            if (refs.querySelector('h3')?.textContent!=='References' || refs.querySelectorAll('p').length!==2 ||
                getComputedStyle(author).whiteSpace!=='pre-line' || refs.querySelector('button,img,.zh')) return false;
            const range=document.createRange();
            range.setStart(author.firstChild,0);range.setEndAfter(refs.lastChild);
            const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
            const event=new Event('copy',{cancelable:true}),clipboard=new DataTransfer();
            Object.defineProperty(event,'clipboardData',{value:clipboard});document.dispatchEvent(event);
            const text=clipboard.getData('text/plain');
            return text.includes('Mira Ellis') && text.includes('Body sentence.') && text.endsWith('[2] Second title.')
              && text.includes('[1] A < B.') && !text.includes('正文。');
            """)
        #expect(valid)
    }

    @Test @MainActor func pdfSentenceLayoutsKeepTheSameRangeWhenAnEarlierTranslationArrives() async throws {
        let sentences = ["a", "b", "c"].map { id in
            PDFSourceSentence(id: id, text: "Repeated line.", pageIndex: 0, rects: [], paragraphID: "p")
        }
        var chosen: String?
        var selection: [String] = []
        func canvas(translations: [String: String], stacked: Bool) -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, layout: stacked ? .stacked : .split,
                fontSize: stacked ? 19 : 16,
                focusedID: "b",
                focusRevision: 1, followsScroll: true, sourceScrollID: nil, sourceScrollRevision: 0,
                pdfSelectedIDs: ["c"],
                onScroll: { _ in }, onSelection: { selection = $0 }, onFocus: { chosen = $0 })
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
                  && b.getAttribute('aria-pressed')==='true'
                  && getComputedStyle(b).backgroundColor!==getComputedStyle(document.getElementById('a')).backgroundColor;
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
    @Test @MainActor func pdfParagraphLayoutKeepsWholeParagraphsAndLinksOnlyMatchingSentences() async throws {
        let sentences = ["Alpha < One.", "Bravo two.", "Charlie three.", "Delta four.", "Echo five."].enumerated().map {
            PDFSourceSentence(
                id: "s\($0.offset)", text: $0.element, pageIndex: 0, rects: [], paragraphID: "extraction",
                readingParagraphID: $0.offset < 4 ? "p1" : "p2"
            )
        }
        var focus: String?
        var selected: [String] = []
        func canvas(_ translations: [String: String], layout: PDFSentenceTextCanvas.Layout = .paragraph)
            -> PDFSentenceTextCanvas
        {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, layout: layout, fontSize: 19, focusedID: "s1",
                focusRevision: 1, followsScroll: true, sourceScrollID: nil, sourceScrollRevision: 0,
                pdfSelectedIDs: [], onScroll: { _ in }, onSelection: { selected = $0 }, onFocus: { focus = $0 })
        }
        let partial = ["s1": "第二句。", "s4": "<img> 是原文。"]
        let view = canvas(partial)
        let coordinator = view.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 560, height: 550)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<160 {
            if (try? await evaluate("return document.querySelectorAll('section').length === 2")) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let paragraphs = try await evaluate(
            """
            const [first, second]=document.querySelectorAll('main section');
            const [en, zh]=first.children;
            return en.lang==='en' && zh.lang==='zh-Hans'
              && en.textContent==='Alpha < One. Bravo two. Charlie three. Delta four.'
              && zh.textContent==='待译第二句。待译' && zh.querySelectorAll('.pending').length===2
              && second.firstChild.textContent==='Echo five.' && second.lastChild.textContent==='<img> 是原文。'
              && document.images.length===0 && document.querySelectorAll('[aria-pressed="true"]').length===2
              && Array.from(document.querySelectorAll('[aria-pressed="true"]')).every(node=>node.dataset.sentence==='s1');
            """)
        #expect(paragraphs)
        let retainedFocus = try await evaluate(
            """
            const zh=document.querySelector('.zh[data-sentence=s4]');
            zh.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,pointerType:'mouse'}));
            return !zh.matches('[aria-pressed="true"]') &&
              [...document.querySelectorAll('[aria-pressed="true"]')].every(el=>el.dataset.sentence==='s1');
            """)
        #expect(retainedFocus && focus == nil)
        for side in ["en", "zh"] {
            focus = nil
            _ = try await evaluate("document.querySelector('.\(side)[data-sentence=s4]').click();return true")
            for _ in 0..<60 where focus == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(focus == "s4")
        }
        _ = try await evaluate(
            """
            const node=document.querySelector('.zh[data-sentence=s1]').firstChild;
            getSelection().setBaseAndExtent(node,1,node,3); return true;
            """)
        for _ in 0..<60 where selected != ["s1"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected == ["s1"])
        let completed = partial.merging(["s0": "第一句。", "s2": "第三句。", "s3": "第四句。"]) { _, new in new }
        coordinator.update(canvas(completed), view: web)
        let preserved = try await evaluate(
            """
            const p=document.querySelector('p[lang="zh-Hans"]');
            return p.textContent==='第一句。第二句。第三句。第四句。' && !document.querySelector('.pending')
              && getSelection().toString()==='二句' && document.querySelector('.counterpart')?.dataset.sentence==='s1';
            """)
        #expect(preserved)
        // A range spanning both languages copies the selected English characters in paragraph order.
        let copiesEnglish = try await evaluate(
            """
            const en=document.querySelectorAll('.en');
            getSelection().setBaseAndExtent(en[3].firstChild,6,en[4].firstChild,4);
            const clipboard=new DataTransfer();
            document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:clipboard,cancelable:true}));
            return clipboard.getData('text/plain')==='four.\\n\\nEcho';
            """)
        #expect(copiesEnglish)
        for _ in 0..<60 where selected != ["s3", "s4"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected == ["s3", "s4"])
        coordinator.update(canvas(completed, layout: .stacked), view: web)
        let restored = try await evaluate(
            """
            const el=document.querySelector('#s1');
            return el.getAttribute('aria-pressed')==='true'
              && el.textContent==='Bravo two.第二句。'
              && getSelection().anchorNode===document.querySelector('#s3 .en').firstChild
              && getSelection().focusNode===document.querySelector('#s4 .en').firstChild;
            """)
        #expect(restored)
    }

    @Test @MainActor func pdfParagraphIllustrationsStayAnchoredDuringTranslationAndOpenTheirOriginalRegion()
        async throws
    {
        let pixel = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGOQkFT4DwAB7wFRYQOP7AAAAABJRU5ErkJggg=="))
        let sentences = [
            PDFSourceSentence(id: "a", text: "Introduction.", pageIndex: 1, rects: [], paragraphID: "intro"),
            PDFSourceSentence(id: "b", text: "Figure 1. Comparison.", pageIndex: 1, rects: [], paragraphID: "caption"),
        ]
        let figure = PDFReadingIllustration(
            id: "figure", label: "图 1", pageIndex: 1, sourceBounds: CGRect(x: 5, y: 10, width: 30, height: 18),
            insertBeforeSentenceID: "b", imagePNG: pixel)
        let table = PDFReadingIllustration(
            id: "table", label: "表 2", pageIndex: 1, sourceBounds: CGRect(x: 7, y: 60, width: 90, height: 30),
            insertBeforeSentenceID: nil, imagePNG: nil)
        var revealed: PDFReadingIllustration?
        func canvas(
            rows: [PDFSourceSentence], translations: [String: String], layout: PDFSentenceTextCanvas.Layout
        ) -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: rows, translations: translations, layout: layout, fontSize: 16, focusedID: nil,
                focusRevision: 0, followsScroll: false, sourceScrollID: nil, sourceScrollRevision: 0,
                pdfSelectedIDs: [], onScroll: { _ in }, onSelection: { _ in }, onFocus: { _ in },
                illustrations: [figure, table], onRevealIllustration: { revealed = $0 })
        }
        let initial = canvas(rows: sentences, translations: [:], layout: .paragraph)
        let coordinator = initial.makeCoordinator()
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 600, height: 440)
        defer { coordinator.stop(web) }
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<160 {
            if (try? await evaluate("return document.images[0]?.naturalWidth===1")) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let placement = try await evaluate(
            """
            const blocks=[...document.querySelector('main').children];
            const sequence=blocks.map(e=>e.dataset.group || e.querySelector('button').dataset.illustration);
            const [image]=document.images;
            window.crop=image;
            const text=document.querySelector('.en[data-sentence=b]').firstChild;
            getSelection().setBaseAndExtent(text,0,text,8);
            return sequence.join(',')==='intro,figure,caption,table' && document.images.length===1 && image.naturalWidth===1
              && image.closest('button').getAttribute('aria-label')==='放大图 1'
              && blocks[3].textContent==='在原页查看表 2';
            """)
        #expect(placement)
        coordinator.update(canvas(rows: sentences, translations: ["a": "简介。"], layout: .paragraph), view: web)
        let preserved = try await evaluate(
            """
            return document.images[0]===window.crop && getSelection().toString()==='Figure 1'
                && document.querySelector('.zh').textContent==='简介。';
            """)
        #expect(preserved)
        for item in [figure, table] {
            revealed = nil
            _ = try await web.callAsyncJavaScript(
                "getSelection().removeAllRanges();document.querySelector('[data-illustration='+id+']').click()",
                arguments: ["id": item.id], in: nil, contentWorld: .defaultClient)
            if item.id == figure.id {
                let preview = try await evaluate(
                    """
                    const dialog=document.querySelector('[aria-modal=true]');
                    const original=[...dialog.querySelectorAll('button')].find(b=>b.textContent==='查看原页');
                    original.click();return true;
                    """)
                #expect(preview)
            }
            for _ in 0..<60 where revealed == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(revealed == item)
        }
        coordinator.update(canvas(rows: [], translations: [:], layout: .paragraph), view: web)
        let onlyFigures = try await evaluate(
            "return document.querySelectorAll('main figure').length===2 && !document.querySelector('[data-sentence]')")
        #expect(onlyFigures)
        coordinator.update(canvas(rows: sentences, translations: ["b": "图注。"], layout: .stacked), view: web)
        let sentenceLayout = try await evaluate(
            "return !document.querySelector('figure') && !!document.querySelector('#b')")
        #expect(sentenceLayout)
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
                sentences: sentences, translations: translations, layout: .split, fontSize: 16, focusedID: nil,
                focusRevision: 0, followsScroll: true, sourceScrollID: sourceID, sourceScrollRevision: revision,
                pdfSelectedIDs: [], onScroll: { movements.append($0) }, onSelection: { _ in },
                onFocus: { _ in })
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
