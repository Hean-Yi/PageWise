#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func pdfReflowReusesTheAnnotationPaletteAndSendsOnlySelectedCharacters() async throws {
        let rows = ["First sentence.", "Second sentence."].enumerated().map { index, text in
            PDFSourceSentence(
                id: "s\(index)", text: text, pageIndex: 0, rects: [], paragraphID: "p",
                characterRanges: [.init(location: index * 20, length: text.utf16.count)])
        }
        var events: [(PDFReflowSelectionAction, [PDFReflowTextSelection])] = []
        var liveSelection: [PDFReflowTextSelection] = []
        var opened: UUID?
        let mark = NoteAnchor(key: "original-0", target: "pdf", text: "First", start: 0, end: 5)
        let translation = "第一句。"
        let translated = NoteAnchor(
            key: "original-0",
            target: NoteAnchor.pdfTranslationTarget(
                sentenceID: "s0", translation: translation), text: "一句", start: 1, end: 3)
        let id = UUID()
        var canvas = PDFSentenceTextCanvas(
            sentences: rows, translations: ["s0": translation, "s1": "第二句。"], layout: .paragraph, fontSize: 16,
            onSelection: { _ in }, onOpenHighlight: { opened = $0 },
            inlineHighlights: [.init(id: UUID(), anchors: [mark], color: .yellow)],
            onTextSelection: { liveSelection = $0 },
            onSelectionAction: { events.append(($0, $1)) })
        let coordinator = canvas.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 540, height: 480)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<150 {
            if (try? await evaluate("return CSS.highlights.get('pdf-yellow-highlight')?.size === 1")) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            try await evaluate(
                """
                const ink=CSS.highlights.get('pdf-yellow-highlight');
                return !!ink && [...ink][0]?.toString()==='First' && !document.querySelector('[data-reading-note]');
                """))
        #expect(
            try await evaluate(
                """
                const [a,b]=document.querySelectorAll('.en'), tools=document.querySelector('#annotation-menu');
                a.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
                getSelection().setBaseAndExtent(b.firstChild,6,a.firstChild,6);
                document.dispatchEvent(new Event('selectionchange'));
                return tools.hidden;
                """))
        _ = try await evaluate("document.dispatchEvent(new PointerEvent('pointerup'));return true")
        for _ in 0..<75 {
            if try await evaluate("return !document.querySelector('#annotation-menu').hidden") { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(
            try await evaluate(
                """
                const tools=document.querySelector('#annotation-menu');
                if (tools.hidden) return false;
                const button=tools.querySelector('.add-note');
                button.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true}));
                button.click();return tools.hidden;
                """))
        for _ in 0..<50 where events.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.first?.0 == .note)
        #expect(events.first?.1.map(\.text) == ["sentence.", "Second"])
        #expect(events.first?.1.map(\.range) == [NSRange(location: 6, length: 9), NSRange(location: 0, length: 6)])
        // A long press can transfer ownership to the system selection handles via pointercancel.
        _ = try await evaluate(
            """
            const zh=document.querySelector('.zh');
            zh.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
            getSelection().setBaseAndExtent(zh.firstChild,1,zh.firstChild,3);
            document.dispatchEvent(new PointerEvent('pointercancel'));return true;
            """)
        for _ in 0..<75 {
            if try await evaluate("return !document.querySelector('#annotation-menu').hidden") { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(
            try await evaluate(
                """
                const tools=document.querySelector('#annotation-menu'), button=tools.querySelector('[data-color=red]');
                if (tools.hidden || tools.querySelectorAll('[data-color]').length!==8 || !tools.querySelector('[data-mode=underline]')) return false;
                button.click();return true;
                """))
        for _ in 0..<50 where events.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.last?.0 == .mark(color: .red, style: .highlight, removing: false))
        #expect(events.last?.1.first?.text == "一句")
        #expect(events.last?.1.first?.language == "zh")
        _ = try await evaluate("document.querySelector('[data-mode=underline]').click();return true")
        for _ in 0..<50 where events.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.last?.0 == .mark(color: .red, style: .underline, removing: false))

        canvas.inlineHighlights.append(.init(id: id, anchors: [translated], color: .red, style: .underline))
        coordinator.update(canvas, view: web)
        let selectedInk = """
            const range=[...CSS.highlights.get('pdf-red-underline')][0],menu=document.querySelector('#annotation-menu');
            return range?.toString()==='一句' && range.startContainer.parentElement.classList.contains('zh')
              && !menu.hidden && menu.querySelector('.remove').textContent==='取消下划线'
              && !menu.querySelector('.remove').hidden && menu.querySelector('[data-color=red]').getAttribute('aria-pressed')==='true';
            """
        #expect(try await evaluate(selectedInk))
        _ = try await evaluate("document.querySelector('#annotation-menu .remove').click();return true")
        for _ in 0..<50 where events.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.last?.0 == .mark(color: .red, style: .underline, removing: true))

        _ = try await evaluate(
            """
            const node=document.querySelector('.zh'),range=[...CSS.highlights.get('pdf-red-underline')][0];
            const r=range.getBoundingClientRect();
            node.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
            getSelection().removeAllRanges();
            node.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:r.x+r.width/2,clientY:r.y+r.height/2}));
            return true;
            """)
        for _ in 0..<50 where !liveSelection.isEmpty || opened == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(liveSelection.isEmpty)
        #expect(opened == id)
        canvas = PDFSentenceTextCanvas(
            sentences: rows, translations: ["s0": "已变更的译文", "s1": "第二句。"], layout: .paragraph, fontSize: 16,
            onSelection: { _ in }, inlineHighlights: canvas.inlineHighlights)
        coordinator.update(canvas, view: web)
        #expect(try await evaluate("return CSS.highlights.get('pdf-red-underline').size===0"))

    }

    @Test @MainActor func pdfSelectionPaintTracksTheSelectedCharactersAcrossSoftWraps() async throws {
        let prose = String(repeating: "There is another reason to be cautious about this result. ", count: 5)
        let row = PDFSourceSentence(id: "en", text: prose, pageIndex: 0, rects: [], paragraphID: "p")
        let canvas = PDFSentenceTextCanvas(
            sentences: [row], translations: ["en": "谨慎看待这一结果。"], layout: .paragraph, fontSize: 18,
            onSelection: { _ in })
        let coordinator = canvas.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 1120, height: 480)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<160 {
            if (try? await evaluate("return !!document.querySelector('.en')?.firstChild")) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let selected = try await evaluate(
            """
            const node=document.querySelector('.en').firstChild;
            const range=document.createRange();range.setStart(node,12);range.setEnd(node,13);
            const top=range.getBoundingClientRect().top;
            let end=13;
            while(end<node.length-7 && range.getBoundingClientRect().top<top+2){
              range.setStart(node,end);range.setEnd(node,++end);
            }
            getSelection().setBaseAndExtent(node,end+6,node,12);
            const clipboard=new DataTransfer();
            document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:clipboard,cancelable:true}));
            return clipboard.getData('text/plain')===node.data.slice(12,end+6);
            """)
        #expect(selected)
        let boundsCheck = """
            const runs=[...getSelection().getRangeAt(0).getClientRects()].filter(r=>r.width>0);
            const ink=[...document.querySelectorAll('#pdf-text-selection span')].map(e=>e.getBoundingClientRect());
            const paper=document.querySelector('p').getBoundingClientRect();
            return runs.length>=2 && runs.length===ink.length && ink.every((r,i)=>
              Math.abs(r.x-runs[i].x)<0.1 && Math.abs(r.y-runs[i].y)<0.1 &&
              Math.abs(r.width-runs[i].width)<0.1 && r.left>=paper.left-1 && r.right<=paper.right+1)
              && getComputedStyle(document.documentElement,'::selection').backgroundColor==='rgba(0, 0, 0, 0)'
              && !document.querySelector('main [aria-pressed=true],main .counterpart');
            """
        for width in [1120, 420] {
            web.frame.size.width = CGFloat(width)
            for _ in 0..<80 {
                if (try? await evaluate(boundsCheck)) == true { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(try await evaluate(boundsCheck))
        }
        _ = try await evaluate("getSelection().removeAllRanges();return true")
        for _ in 0..<80 {
            if try await evaluate("return !document.querySelector('#pdf-text-selection span')") { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(
            try await evaluate(
                "return !document.querySelector('.reading-range, .counterpart, #pdf-text-selection span')"))
    }

    @Test @MainActor func pdfReflowNotesUnderlineOnlyAnchoredCharactersAndOpenTheirEditor() async throws {
        let sentence = PDFSourceSentence(
            id: "s", text: "word then word.", pageIndex: 0, rects: [], paragraphID: "p",
            characterRanges: [NSRange(location: 30, length: 15)])
        let id = UUID()
        let anchor = NoteAnchor(key: "original-0", target: "pdf", text: "word", start: 40, end: 44)
        var opened: UUID?
        var canvas = PDFSentenceTextCanvas(
            sentences: [sentence], translations: ["s": "对照"], layout: .paragraph, fontSize: 18, onSelection: { _ in },
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
            onSelection: { _ in },
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
        var selection: [String] = []
        func canvas(translations: [String: String], fontSize: Int) -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, layout: .split, fontSize: fontSize,
                onSelection: { selection = $0 })
        }
        let initial = ["b": "中间的重复句。", "c": "中间的重复句。"]
        let first = canvas(translations: initial, fontSize: 16)
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
        coordinator.update(canvas(translations: completed, fontSize: 19), view: web)
        let preserved =
            try await web.callAsyncJavaScript(
                """
                const p=document.querySelector('p'), b=document.getElementById('b');
                return p.children.length===3 && [...p.children].map(s=>s.id).join('')==='abc'
                  && document.images.length===0 && document.body.textContent.includes("<img src='x'>")
                  && b===window.original && getSelection().toString()==='中间'
                  && getComputedStyle(b.firstChild).display==='none' && getComputedStyle(b.lastChild).fontSize==='19px'
                  && !b.hasAttribute('aria-pressed')
                  && getComputedStyle(b).backgroundColor===getComputedStyle(document.getElementById('a')).backgroundColor;
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
    }
    @Test @MainActor func pdfParagraphLayoutPreservesSelectionWithoutActivatingOrHighlightingCounterparts() async throws
    {
        let sentences = ["Alpha < One.", "Bravo two.", "Charlie three.", "Delta four.", "Echo five."].enumerated().map {
            PDFSourceSentence(
                id: "s\($0.offset)", text: $0.element, pageIndex: 0, rects: [], paragraphID: "extraction",
                readingParagraphID: $0.offset < 4 ? "p1" : "p2"
            )
        }
        var selected: [String] = []
        func canvas(_ translations: [String: String], layout: PDFSentenceTextCanvas.Layout = .paragraph)
            -> PDFSentenceTextCanvas
        {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: translations, layout: layout, fontSize: 19,
                onSelection: { selected = $0 })
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
              && document.images.length===0 && !document.querySelector('main [role=button],main [aria-pressed]');
            """)
        #expect(paragraphs)
        let retainedFocus = try await evaluate(
            """
            const zh=document.querySelector('.zh[data-sentence=s4]');
            zh.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,pointerType:'mouse'}));
            zh.click();
            return !document.querySelector('main [aria-pressed],.related,.counterpart') && getSelection().isCollapsed;
            """)
        #expect(retainedFocus)
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
              && getSelection().toString()==='二句' && !document.querySelector('main .counterpart, main [aria-pressed]');
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
        // Switching to the original/translation split keeps Chinese plain, without a sentence action.
        coordinator.update(canvas(completed, layout: .split), view: web)
        #expect(
            try await evaluate(
                "return !document.querySelector('main [role=button]') && !!document.querySelector('#s1 .zh')"))
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
                sentences: rows, translations: translations, layout: layout, fontSize: 16, onSelection: { _ in },
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
        coordinator.update(canvas(rows: sentences, translations: ["b": "图注。"], layout: .split), view: web)
        let sentenceLayout = try await evaluate(
            "return !document.querySelector('figure') && !!document.querySelector('#b')")
        #expect(sentenceLayout)
    }

#endif
