#if os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing
    import WebKit
    @testable import PaperReaderUI

    @Test @MainActor func readingNoteCardPersistsAcrossSidebarChangesAndAnnotationRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try ReaderModel(root: directory)
        await model.load()
        let block = TextBlock(sourcePage: 0, text: "Alpha beta gamma delta evidence.")
        var paper = Paper(
            title: "Note fixture", digest: "notes", originalPath: "unused.pdf", pageCount: 1, blocks: [block],
            warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            [BilingualBlock(block: block, translation: "中文证据与想法。")], to: nil, paper: paper, root: directory)
        paper.translatedBlockCount = 1
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await noteWait { (try? await noteJS(web, "return !!window.paperNotes")) as? Bool == true }
        _ = try await noteJS(
            web,
            "window.p=document.querySelector('section p');window.original=p.outerHTML;window.height=p.getBoundingClientRect().height;getSelection().setBaseAndExtent(p.firstChild,1,p.firstChild,8)"
        )
        try await noteWait { model.selectionText == "lpha be" }
        _ = try await noteJS(web, "document.querySelector('#annotation-menu .add-note').click()")
        #expect(try await noteJS(web, "return window.paperNotes.editing()") as? Bool == true)
        #expect(
            try await noteJS(web, "return document.querySelector('#annotation-menu').classList.contains('note-docked')")
                as? Bool == true)
        var source =
            "# My note\n\n**Evidence** $x^2$\n\n" + String(repeating: "Long content stays accessible.\n\n", count: 20)
        _ = try await web.callAsyncJavaScript(
            "window.editor=document.querySelector('.reader-note-card textarea');editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}));editor.setSelectionRange(3,6)",
            arguments: ["source": source], in: nil, contentWorld: .defaultClient)
        try await noteWait { model.currentReadingNotes.count == 1 }
        #expect(model.currentReadingNotes[0].anchors[0].text == "lpha be")
        #expect(model.currentHighlights.isEmpty)
        coordinator.update(web, sidebarOpen: false)
        try await noteWait {
            (try? await noteJS(web, "return document.querySelector('.reader-note-card').dataset.placement")) as? String
                == "right"
        }
        #expect(
            try await noteJS(web, "return editor.value===source && editor.selectionStart===3", ["source": source])
                as? Bool == true)
        _ = try await noteJS(web, "document.querySelector('[data-color=blue]').click()")
        try await noteWait { model.currentHighlights.count == 1 }
        coordinator.update(web)
        _ = try await noteJS(web, "document.querySelector('[data-mode=underline]').click()")
        try await noteWait { model.currentHighlights.first?.style == .underline }
        coordinator.update(web)
        _ = try await noteJS(web, "document.querySelector('#annotation-menu .remove').click()")
        try await noteWait { model.currentHighlights.isEmpty }
        #expect(model.currentReadingNotes.count == 1)
        coordinator.update(web, sidebarOpen: true)
        try await noteWait {
            (try? await noteJS(web, "return document.querySelector('.reader-note-card').dataset.placement")) as? String
                == "floating"
        }
        try await noteWait {
            (try? await noteJS(web, "return !!document.querySelector('.note-content math')")) as? Bool == true
        }
        source += "\n\n**Live update** $z_1$"
        _ = try await noteJS(
            web,
            "editor.value='Old preview';editor.dispatchEvent(new Event('input',{bubbles:true}));editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}))",
            ["source": source])
        try await noteWait {
            (try? await noteJS(
                web,
                "return [...document.querySelectorAll('.note-content strong')].some(e=>e.textContent==='Live update') && document.querySelectorAll('.note-content math').length===2"
            )) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                "return getComputedStyle(document.querySelector('.note-content')).display!=='none' && getComputedStyle(editor).display!=='none'"
            ) as? Bool == true)
        #expect(
            try await noteJS(
                web,
                "return document.querySelector('.reader-note-card').getBoundingClientRect().height<=420 && p.outerHTML===original && p.getBoundingClientRect().height===height"
            ) as? Bool == true)
        _ = try await noteJS(web, "window.paperNotes.finish()")
        await model.flushReadingNotes()
        #expect(model.savedNoteRevision == model.noteRevision)
        coordinator.update(web, sidebarOpen: false)
        try await noteWait {
            (try? await noteJS(
                web,
                "return !document.querySelector('.reader-note-card').hidden && !document.querySelector('.reader-note-card').classList.contains('active')"
            )) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                "return document.querySelector('.reader-note-card').getBoundingClientRect().height<=112 && document.querySelectorAll('.note-wave').length>0 && !document.querySelector('.note-link')"
            ) as? Bool == true)
        // Scrolling must use native document coordinates, without rebuilding decorations or relocating cards.
        _ = try await noteJS(
            web,
            "const pad=document.createElement('div');pad.style.height='2000px';document.body.append(pad);window.wave=document.querySelector('.note-wave');window.card=document.querySelector('.reader-note-card');window.documentTop=card.getBoundingClientRect().top+scrollY;window.placements=0;const place=paperNoteLayout.place;paperNoteLayout.place=(...a)=>{placements++;return place(...a)};window.scrollTo(0,120)"
        )
        try await noteWait { (try? await noteJS(web, "return scrollY===120")) as? Bool == true }
        #expect(
            try await noteJS(
                web,
                "return document.querySelector('.note-wave')===wave && Math.abs(card.getBoundingClientRect().top+scrollY-documentTop)<0.5 && placements===0"
            ) as? Bool == true)
        _ = try await noteJS(web, "window.scrollTo(0,0)")
        try await noteWait { (try? await noteJS(web, "return scrollY===0")) as? Bool == true }
        // Hover works in both directions; the connector leaves beneath the text, not through it.
        _ = try await noteJS(
            web,
            "window.anchor=paperNoteLayout.rects(paperSelection.parts()).at(0);const r=document.createRange();r.setStart(p.firstChild,1);r.setEnd(p.firstChild,8);window.anchor=r.getBoundingClientRect();p.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:anchor.left+2,clientY:anchor.top+2}))"
        )
        try await noteWait {
            (try? await noteJS(web, "return !!document.querySelector('.note-link')")) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                "window.forward=document.querySelector('.note-link').getAttribute('d');return Number(forward.split(' ')[2])>anchor.bottom && document.querySelectorAll('#reader-note-lift span').length>0"
            ) as? Bool == true)
        _ = try await noteJS(
            web, "document.querySelector('.reader-note-card').dispatchEvent(new MouseEvent('mouseenter'))")
        try await noteWait {
            (try? await noteJS(web, "return document.querySelector('.note-link')?.getAttribute('d')!==forward"))
                as? Bool == true
        }
        let saved = try #require(model.currentReadingNotes.first)
        let reopened = try ReaderModel(root: directory)
        await reopened.load()
        #expect(reopened.state.readingNotes == [saved])
        model.deleteReadingNote(saved.id)
        #expect(model.currentReadingNotes.isEmpty)
        model.undoReadingNoteDeletion()
        #expect(model.currentReadingNotes.first?.markdown == source)
        coordinator.update(web)
        _ = try await noteJS(web, "window.paperNotes.open(id,true)", ["id": saved.id.uuidString])
        #expect(try await noteJS(web, "return editor.value", [:]) as? String == source)
        #expect(
            try await noteJS(
                web,
                "const r=document.querySelector('.reader-note-card').getBoundingClientRect();return [...document.querySelectorAll('#annotation-menu .swatch')].every(e=>{const b=e.getBoundingClientRect();return b.left>=r.left && b.right<=r.right;})"
            ) as? Bool == true)
        #expect(
            try await noteJS(
                web,
                "const e=new ClipboardEvent('copy',{clipboardData:new DataTransfer(),cancelable:true});document.dispatchEvent(e);return !e.defaultPrevented"
            ) as? Bool == true)
        _ = try await noteJS(web, "window.paperNotes.finish()")
        model.select(nil)
    }

    @Test @MainActor func readingNoteSaveFailureRetainsDraftAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = root.appendingPathExtension("saved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: backup)
        }
        let model = try ReaderModel(root: root)
        await model.load()
        let note = ReadingNote(
            paperID: UUID(), contentVersion: "stable",
            anchors: [NoteAnchor(key: "a", target: "source", text: "word", start: 0, end: 4)],
            markdown: "Never lose $x^2$.")
        model.state.readingNotes = [note]
        model.noteRevision = 1
        try FileManager.default.moveItem(at: root, to: backup)
        await model.flushReadingNotes()
        #expect(model.noteSaveFailed)
        #expect(model.savedNoteRevision == 0)
        #expect(model.state.readingNotes == [note])
        try FileManager.default.moveItem(at: backup, to: root)
        await model.flushReadingNotes()
        #expect(!model.noteSaveFailed)
        #expect(model.savedNoteRevision == 1)
        let reopened = try ReaderModel(root: root)
        await reopened.load()
        #expect(reopened.state.readingNotes == [note])
    }

    @MainActor private func noteJS(_ web: WKWebView, _ source: String, _ arguments: [String: Any] = [:]) async throws
        -> Any?
    {
        try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }
    @MainActor private func noteWait(line: Int = #line, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Note card condition not satisfied at caller line \(line)")
    }
#endif
