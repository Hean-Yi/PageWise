#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    /// The built-in sample wraps the first selected sentence in the PDF and again in the Web view.
    @Test(arguments: [false, true]) @MainActor
    func clickingAnyPartOfAWrappedStrokeEditsAndLiftsTheWholePassage(legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let original = try DemoPaper.fileURL()
        let paperID = try #require(await model.importURLs([original]).first)
        let session = model.pdfBilingual
        session.open(model)
        defer { session.close() }
        func eventually(_ test: () async throws -> Bool) async throws -> Bool {
            for _ in 0..<150 {
                if (try? await test()) == true { return true }
                try await Task.sleep(for: .milliseconds(30))
            }
            return try await test()
        }
        try #require(try await eventually { session.paragraphPages[0] != nil })
        let page = try #require(session.paragraphPages[0])
        let first = try #require(page.sentences.first { $0.text.contains("We build a small example") })
        let last = try #require(page.sentences.first { $0.text.contains("The reversal comes") })
        let parts = [first, last].map {
            PDFReflowTextSelection(
                sentence: $0, language: "en", range: NSRange(location: 0, length: $0.text.utf16.count), text: $0.text)
        }
        await model.performReflowSelectionAction(
            .mark(color: .yellow, style: .highlight, removing: false), selection: parts)
        let ink = model.currentHighlights
        try #require(ink.count > 1 && ink.first?.strokeID != nil)
        #expect(Set(ink.map(\.strokeID)).count == 1)
        let expected = ink.compactMap(\.pdfReadingAnchor)
        let lastMark = try #require(ink.last)
        if legacy {
            let base = Date(timeIntervalSinceReferenceDate: 12345)
            for index in model.state.highlights.indices {
                model.state.highlights[index].strokeID = nil
                model.state.highlights[index].createdAt = base.addingTimeInterval(Double(index) / 100_000)
            }
            let note = ReadingNote(
                paperID: paperID, contentVersion: try #require(model.paper).digest + ":original-0",
                anchors: [try #require(lastMark.pdfReadingAnchor)], markdown: "旧版留下的笔记")
            model.state.readingNotes = [note]
            model.state.version = 12
            model.state = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(model.state))
            #expect(model.currentReadingNotes.first?.legacyStrokeMemberID == lastMark.id)
            #expect(model.currentReadingNotes.first?.modifiedAt == note.modifiedAt)
        } else {
            await model.openPDFHighlightNote(lastMark, inReflow: true)?.value
            let draft = try #require(model.pdfNoteEditor)
            #expect(draft.note.anchors == expected)
            #expect(model.updateReadingNote(id: draft.id, anchors: draft.note.anchors, markdown: "新建的笔记"))
            model.closePDFReadingNote()
        }
        await session.locateHistoricalInk(session.historicalHighlights(in: model), model: model)
        let stable = try #require(model.currentReadingNotes.first)
        #expect(model.reflowInlinePDFNotes.first?.anchors == expected)
        let firstMark = try #require(model.currentHighlights.first)
        await model.openPDFHighlightNote(firstMark, inReflow: true)?.value
        #expect(model.pdfNoteEditor?.id == stable.id && model.pdfNoteEditor?.note.anchors == stable.anchors)
        model.closePDFReadingNote()
        func canvas() -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: page.sentences, translations: [:], layout: .paragraph, fontSize: 16, onSelection: { _ in },
                continuous: .init(
                    paperID: paperID, pageCount: model.paper?.pageCount ?? 0, pages: session.paragraphPages,
                    targetPage: 0, jumpRevision: 0, onVisiblePage: { _ in }, onOpenOriginalPage: { _ in }),
                inlineNotes: model.reflowInlinePDFNotes, inlineHighlights: model.inlinePDFHighlights, noteModel: model,
                sidebarOpen: true)
        }
        let coordinator = canvas().makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 720, height: 680)
        func js(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Bool {
            try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
                as? Bool == true
        }
        let noteID = stable.id.uuidString
        try #require(
            try await eventually {
                try await js(
                    "return !!document.querySelector('.reader-note-card[data-note-id=\"'+id+'\"]')", ["id": noteID])
            })
        let combined = first.text + last.text
        for sentence in [first, last] {
            _ = try await js(
                """
                const span=document.querySelector('.en[data-sentence="'+sentence+'"]');
                span.scrollIntoView({block:'center'});
                const r=document.createRange();r.setStart(span.firstChild,1);r.setEnd(span.firstChild,2);
                const b=r.getClientRects()[0],pos={bubbles:true,clientX:b.left+b.width/2,clientY:b.bottom+3};
                span.dispatchEvent(new PointerEvent('pointermove',pos));
                span.dispatchEvent(new PointerEvent('pointerdown',pos));
                span.dispatchEvent(new MouseEvent('click',{...pos,detail:1}));return true;
                """, ["sentence": sentence.id])
            try #require(
                try await eventually {
                    try await js(
                        #"""
                        const card=document.querySelector('.reader-note-card.active:not([hidden])');
                        const text=[...document.querySelectorAll('#reader-note-lift .note-lift-text')].map(s=>s.textContent).join('');
                        return card?.dataset.noteId===id && paperNotes.editing() && card.querySelector('.note-editor')?.value===body
                          && text.replace(/\s/g,'')===combined.replace(/\s/g,'');
                        """#, ["id": noteID, "body": stable.markdown, "combined": combined])
                })
            #expect(model.pdfNoteEditor?.id == stable.id)
            if sentence.id == last.id {
                _ = try await js(
                    """
                    const editor=document.querySelector('.editing-live .note-editor');
                    editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}));return true;
                    """, ["source": stable.markdown + " 补记。"])
                try #require(
                    try await eventually { model.currentReadingNotes.first?.markdown == stable.markdown + " 补记。" })
            }
            _ = try await js("paperNotes.finish();return true")
            try #require(try await eventually { model.pdfNoteEditor == nil })
        }
        await model.flushReadingNotes()
        #expect(model.currentReadingNotes.map(\.id) == [stable.id])
        #expect(model.currentReadingNotes.first?.anchors == stable.anchors)
        #expect(model.currentReadingNotes.first?.legacyStrokeMemberID == stable.legacyStrokeMemberID)
        #expect(model.currentReadingNotes.first?.citations == stable.citations)
    }

    @Test @MainActor func reflowProjectionUsesExactRenderedOffsetsForRepeatedPunctuation() throws {
        let source = PDFSourceSentence(
            id: "p0-s11", text: "labels, ...", pageIndex: 0, rects: [], paragraphID: "p",
            characterRanges: [NSRange(location: 11, length: 7), NSRange(location: 33, length: 3)],
            renderedRanges: [NSRange(location: 0, length: 7), NSRange(location: 8, length: 3)])
        let anchor = NoteAnchor(key: "original-0", target: "pdf", text: ".", start: 34, end: 35)
        let note = PDFInlineNote(id: UUID(), anchors: [anchor], color: nil)
        let marks = PDFSentenceTextCanvas.Coordinator.noteMarks(in: [source], notes: [note])
        #expect(marks.first?["ranges"] as? [[Int]] == [[9, 10]])
    }

    private actor SuspendedStrokeLocator: PDFStrokeLocating {
        private var lookup: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        func waitForLookup() async {
            if lookup == nil { await withCheckedContinuation { arrival = $0 } }
        }
        func resume() {
            lookup?.resume()
            lookup = nil
        }
        func anchors(forStroke marks: [Highlight], in url: URL) async throws -> [NoteAnchor] {
            await withCheckedContinuation { pending in
                lookup = pending
                arrival?.resume()
                arrival = nil
            }
            return marks.compactMap(\.pdfReadingAnchor)
        }
        func historicalInk(_ marks: [Highlight], in url: URL) async throws -> (
            anchors: [UUID: [NoteAnchor]], strokes: [UUID: [NoteAnchor]]
        ) { ([:], [:]) }
    }

    enum NextNoteAction: CaseIterable { case close, existingNote, translation }

    @Test(arguments: NextNoteAction.allCases) @MainActor
    func slowPDFInkLookupCannotReplaceANewerEditor(next: NextNoteAction) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let id = try #require(await model.importURLs([try DemoPaper.fileURL()]).first)
        let page = "original-0"
        var slow = Highlight(paperID: id, pageKey: page, pageIndex: 0, text: "a", rects: [])
        slow.strokeID = UUID()
        slow.pdfTextStart = 0
        var chinese = Highlight(paperID: id, pageKey: page, pageIndex: 0, text: "读", rects: [])
        chinese.textRange = [0, 1]
        chinese.pdfTranslationTarget = NoteAnchor.pdfTranslationTarget(sentenceID: "s", translation: "读")
        let existing = ReadingNote(
            paperID: id, contentVersion: try #require(model.paper).digest + ":original-0",
            anchors: [NoteAnchor(key: page, target: "pdf", text: "b", start: 100, end: 101)], markdown: "Saved.")
        model.state.highlights = [slow, chinese]
        model.state.readingNotes = [existing]
        let locator = SuspendedStrokeLocator()
        let first = try #require(model.openPDFHighlightNote(slow, locator: locator))
        await locator.waitForLookup()
        switch next {
        case .close: model.closePDFReadingNote()
        case .existingNote: model.openReadingNote(existing, onOriginalPDF: true)
        case .translation: model.openPDFHighlightNote(chinese)
        }
        let chosen = model.pdfNoteEditor?.note
        #expect(next == .close ? chosen == nil : chosen != nil)
        await locator.resume()
        await first.value
        #expect(model.pdfNoteEditor?.note == chosen)
    }
#endif
