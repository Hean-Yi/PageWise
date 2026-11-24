#if os(macOS)
    import Foundation
    import PaperReaderKit
    import PaperReaderTestSupport
    import Testing
    import WebKit

    @testable import PaperReaderUI

    enum PDFNoteSurface: CaseIterable {
        case englishParagraph, translatedParagraph, translatedSplit
    }

    @Test(arguments: PDFNoteSurface.allCases) @MainActor
    func continuousPDFSelectionCreatesOneEditableMarginNote(surface: PDFNoteSurface) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try ReaderModel(root: directory, credentials: WorkflowCredentials())
        await model.load()
        let file = directory.appendingPathComponent("paper.pdf")
        try AttentionFixture.write(to: file)
        let paperID = try #require(await model.importURLs([file]).first)
        let session = model.pdfBilingual
        session.open(model)
        defer { session.close() }
        func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
            for _ in 0..<160 {
                if (try? await condition()) == true { return true }
                try await Task.sleep(for: .milliseconds(25))
            }
            return try await condition()
        }
        try #require(try await eventually { session.paragraphPages[0] != nil })
        let page = try #require(session.paragraphPages[0])
        let split = surface == .translatedSplit
        let language = surface == .englishParagraph ? "en" : "zh"
        let sentences = split ? session.sentences : page.sentences
        let sentence = try #require(sentences.first { $0.text.contains("notebook") })
        let word = language == "en" ? "notebook" : "笔记本"
        session.receiveDocumentTranslations([sentence.id: "想象一本笔记本。"], paperID: paperID, page: 0)
        var sidebarOpen = false
        func canvas() -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: sentences, translations: session.translations, layout: split ? .split : .paragraph,
                fontSize: 16, onSelection: { _ in },
                continuous: split
                    ? nil
                    : .init(
                        paperID: paperID, pageCount: model.paper?.pageCount ?? 0, pages: session.paragraphPages,
                        targetPage: 0, jumpRevision: 0, onVisiblePage: { _ in }, onOpenOriginalPage: { _ in }),
                inlineNotes: model.reflowInlinePDFNotes, inlineHighlights: model.inlinePDFHighlights,
                onTextSelection: { session.reflowTextSelection = $0 },
                onSelectionAction: { action, selection in
                    Task { await model.performReflowSelectionAction(action, selection: selection) }
                }, noteModel: model, sidebarOpen: sidebarOpen)
        }
        let coordinator = canvas().makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: split ? 520 : 1500, height: 900)
        func evaluate(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Bool {
            try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
                as? Bool == true
        }
        let selector = ".\(language)[data-sentence='\(sentence.id)']"
        try #require(
            try await eventually {
                try await evaluate("return !!document.querySelector(selector)?.firstChild", ["selector": selector])
            })
        _ = try await evaluate(
            """
            const field=document.querySelector(selector), text=field.firstChild, i=text.data.indexOf(word);
            field.scrollIntoView({block:'center'});
            field.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
            getSelection().setBaseAndExtent(text,i,text,i+word.length);
            document.dispatchEvent(new PointerEvent('pointerup'));return true;
            """, ["selector": selector, "word": word])
        try #require(
            try await eventually { try await evaluate("return !document.querySelector('#annotation-menu').hidden") })
        _ = try await evaluate("document.querySelector('#annotation-menu .add-note').click();return true")
        try #require(try await eventually { model.pdfNoteEditor != nil })
        let draft = try #require(model.pdfNoteEditor)
        #expect(draft.note.anchors.map(\.text) == [word])
        coordinator.update(canvas(), view: web)
        let sideCard = ".reader-note-card[data-placement=\(split ? "floating" : "right")]:not([hidden])"
        try #require(
            try await eventually {
                try await evaluate(
                    "return !!document.querySelector(selector+' .note-editor .cm-content')", ["selector": sideCard])
            })
        let matchesSavedInk = """
            const noteColors=['pdf-reading-notes','pdf-notes-red','pdf-notes-blue','pdf-notes-green','pdf-notes-purple'];
            if(noteColors.some(name=>CSS.highlights.get(name)?.size))return false;
            const ink=[...CSS.highlights].flatMap(([name,paint])=>/^pdf-.*-(highlight|underline)$/.test(name)
              ? [...paint].map(range=>name+' '+range.toString()) : []);
            return JSON.stringify(ink.sort())===JSON.stringify(expected.sort());
            """
        #expect(try await evaluate(matchesSavedInk, ["expected": [String]()]))
        let markdown = "**读到这里**，需要回查实验条件。"
        _ = try await evaluate(
            """
            window.editor=document.querySelector('.reader-note-card .note-editor');
            editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}));
            editor.setSelectionRange(3,6);return true;
            """, ["source": markdown])
        try #require(try await eventually { model.currentReadingNotes.first?.markdown == markdown })
        coordinator.update(canvas(), view: web)
        let expectedInk = model.inlinePDFHighlights.flatMap { mark in
            mark.anchors.map {
                "pdf-\((mark.color ?? .yellow).rawValue)-\((mark.style ?? .highlight).rawValue) \($0.text)"
            }
        }
        #expect(try await evaluate(matchesSavedInk, ["expected": expectedInk]))
        _ = try await evaluate(
            "document.querySelector('.reader-note-card [aria-label=\"引用阅读笔记\"]').click();return true")
        try #require(
            try await eventually {
                guard case .picker(let picker) = model.notePassageSheet else { return false }
                return picker.noteID == draft.id && picker.anchors == draft.note.anchors
                    && picker.range == NSRange(location: 3, length: 3)
            })
        model.notePassageSheet = nil
        if split {
            _ = try await evaluate("paperNotes.finish();return true")
            let saved = try #require(model.currentReadingNotes.first)
            try #require(try await eventually { model.pdfNoteEditor == nil })
            let other = try #require(sentences.first { $0.id != sentence.id })
            session.receiveDocumentTranslations(
                [sentence.id: "此处改译为实验记录。", other.id: "笔记本。"], paperID: paperID, page: 0)
            model.openReadingNote(saved)
            coordinator.update(canvas(), view: web)
            try #require(
                try await eventually {
                    model.pdfNoteEditor?.id == saved.id && model.pdfNoteEditor?.usesReflowMargin == false
                })
            #expect(model.pdfNoteEditor?.note.markdown == markdown)
            #expect(model.pdfNoteEditor?.note.anchors == saved.anchors)
            #expect(
                try await evaluate("return !document.querySelector('.reader-note-card:not([hidden]),.sentence-note')"))
            return
        }
        sidebarOpen = true
        coordinator.update(canvas(), view: web)
        try #require(
            try await eventually {
                try await evaluate(
                    """
                    const cards=document.querySelectorAll('.reader-note-card');
                    return cards.length===1 && cards[0].dataset.placement==='floating'
                      && cards[0].contains(editor) && editor.selectionStart===3 && editor.value===source;
                    """, ["source": markdown])
            })
        _ = try await evaluate("paperNotes.finish();return true")
        sidebarOpen = false
        coordinator.update(canvas(), view: web)
        try #require(
            try await eventually {
                try await evaluate(
                    """
                    const card=document.querySelector(cardSelector+':not(.active)');
                    if(!card || document.querySelector('.sentence-note'))return false;
                    const line=document.querySelector(textSelector).closest('p').getBoundingClientRect();
                    const box=card.getBoundingClientRect();
                    return box.left>=line.right && box.right<=innerWidth+1 && box.width>0 && box.height>0;
                    """, ["cardSelector": sideCard, "textSelector": selector])
            })
        _ = try await evaluate(
            """
            const span=document.querySelector(selector), node=span.firstChild, offset=node.data.indexOf(word);
            const range=document.createRange();range.setStart(node,offset);range.setEnd(node,offset+word.length);
            const box=range.getClientRects()[0];
            span.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:box.left+1,clientY:box.top+1}));
            return true;
            """, ["selector": selector, "word": word])
        try #require(
            try await eventually {
                try await evaluate(
                    """
                    return !!document.querySelector('.reader-note-card.active .note-content')
                        && !!document.querySelector('.note-link') && !paperNotes.editing();
                    """)
            })
        _ = try await evaluate("document.querySelector(selector).click();return true", ["selector": sideCard])
        try #require(
            try await eventually {
                try await evaluate("return paperNotes.editing() && editor.value===source", ["source": markdown])
            })
        _ = try await evaluate(
            "editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}));paperNotes.finish();return true",
            ["source": markdown + " 已核对。"])
        try #require(try await eventually { model.currentReadingNotes.first?.markdown == markdown + " 已核对。" })
        await model.flushReadingNotes()
        let saved = try #require(model.currentReadingNotes.first)
        #expect(model.currentReadingNotes.map(\.id) == [draft.id])
        #expect(saved.anchors == draft.note.anchors)
        model.openReadingNote(saved)
        #expect(session.isOpen && model.pdfNoteEditor?.id == saved.id)
    }
#endif
