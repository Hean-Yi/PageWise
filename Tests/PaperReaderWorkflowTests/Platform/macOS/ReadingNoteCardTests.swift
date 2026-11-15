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
        try await noteWait {
            (try? await noteJS(
                web, "return document.querySelector('.reader-note-card').getAnimations().some(a=>a.id==='note-emerge')"))
                as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                "return !!document.querySelector('.note-link') && document.activeElement.closest('.note-editor')!==null && p.outerHTML===original && p.getBoundingClientRect().height===height"
            ) as? Bool == true)
        _ = try await noteJS(
            web, "for(const a of document.querySelector('.reader-note-card').getAnimations())a.finish()")
        try await noteWait { (try? await noteJS(web, "return !document.querySelector('.note-link')")) as? Bool == true }

        #expect(
            try await noteJS(web, "return document.querySelector('#annotation-menu').classList.contains('note-docked')")
                as? Bool == true)
        var source =
            "# My note\n\n**Evidence** $x^2$\n\n" + String(repeating: "Long content stays accessible.\n\n", count: 20)
        _ = try await web.callAsyncJavaScript(
            "window.editor=document.querySelector('.reader-note-card .note-editor');editor.value=source;editor.dispatchEvent(new Event('input',{bubbles:true}));editor.setSelectionRange(3,6)",
            arguments: ["source": source], in: nil, contentWorld: .defaultClient)
        try await noteWait { model.currentReadingNotes.count == 1 }
        #expect(
            try await noteJS(
                web,
                "const pos=editor.value.indexOf('Evidence')+2;editor.setSelectionRange(pos,pos);editor.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',code:'ArrowRight',bubbles:true}));const moved=editor.selectionStart===pos+1;editor.setSelectionRange(3,6);return moved"
            ) as? Bool == true)
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
                "return getComputedStyle(document.querySelector('.note-content')).display==='none' && getComputedStyle(editor).display!=='none' && !!editor.querySelector('.cm-content') && !document.querySelector('.reader-note-card textarea')"
            ) as? Bool == true)
        #expect(
            try await noteJS(
                web,
                "return document.querySelector('.reader-note-card').getBoundingClientRect().height<=420 && p.outerHTML===original && p.getBoundingClientRect().height===height"
            ) as? Bool == true)
        try await noteWait {
            (try? await noteJS(web, "return editor.querySelectorAll('math').length===2")) as? Bool == true
        }
        _ = try await noteJS(
            web,
            "window.mathPosition=editor.value.indexOf('$z_1$');editor.setSelectionRange(mathPosition+2,mathPosition+2)")
        #expect(try await noteJS(web, "return editor.querySelectorAll('math').length===1") as? Bool == true)
        _ = try await noteJS(web, "editor.noteEditor.view.dispatch({changes:{from:mathPosition+4,insert:'^2'}})")
        try await noteWait { model.currentReadingNotes.first?.markdown.contains("$z_1^2$") == true }
        _ = try await noteJS(web, "editor.noteEditor.undo()")
        try await noteWait { model.currentReadingNotes.first?.markdown == source }
        _ = try await noteJS(web, "editor.setSelectionRange(editor.value.length,editor.value.length)")
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
        // WebKit pauses visual animation clocks in the offscreen fixture. Settle before checking final geometry.
        _ = try await noteJS(
            web, "for(const a of document.querySelector('.reader-note-card').getAnimations())a.finish()")
        #expect(
            try await noteJS(
                web,
                "return document.querySelector('.reader-note-card').getBoundingClientRect().height<=168.5 && document.querySelectorAll('.note-wave').length>0 && !document.querySelector('.note-link')"
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
        // Hover works in both directions; the direct connector floats above text without intercepting it.
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
                #"""
                window.forward=document.querySelector('.note-link').getAttribute('d');
                const decoration=getComputedStyle(document.querySelector('#reader-note-decoration')),lift=getComputedStyle(document.querySelector('#reader-note-lift'));
                return Math.abs(Number(forward.split(' ')[2])-(anchor.top+anchor.bottom)/2)<.5
                  && !forward.includes(' L ') && forward.includes(' C ')
                  && Number(decoration.zIndex)>Number(lift.zIndex) && decoration.pointerEvents==='none'
                  && document.querySelectorAll('#reader-note-lift span').length>0;
                """#
            ) as? Bool == true)
        _ = try await noteJS(
            web, "document.querySelector('.reader-note-card').dispatchEvent(new MouseEvent('mouseenter'))")
        try await noteWait {
            (try? await noteJS(web, "return document.querySelector('.note-link')?.getAttribute('d')!==forward"))
                as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                "return document.querySelectorAll('.note-link-start,.note-link-end').length===2 && document.querySelector('.note-wave').getAttribute('d').includes(' C ')"
            ) as? Bool == true)
        _ = try await noteJS(
            web,
            "document.dispatchEvent(new PointerEvent('pointermove',{clientX:0,clientY:0}));await new Promise(resolve=>setTimeout(resolve,60))"
        )
        #expect(
            try await noteJS(web, "return !document.querySelector('.reader-note-card').classList.contains('active')")
                as? Bool == true)
        _ = try await noteJS(
            web,
            "for(let i=0;i<8;i++)p.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:anchor.left+2+i,clientY:anchor.top+2}));await new Promise(resolve=>setTimeout(resolve,60))"
        )
        #expect(
            try await noteJS(web, "return document.querySelector('.reader-note-card').classList.contains('active')")
                as? Bool == true)
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
        try await noteWait {
            (try? await noteJS(
                web,
                "const card=document.querySelector('.reader-note-card');return !card.getAnimations().some(a=>a.id==='note-emerge') && card.style.willChange==='';"
            )) as? Bool == true
        }
        model.select(nil)
    }

    @Test @MainActor func clickingChineseAnnotationUsesExactHitAndDoesNotPaintCollapsedWhitespace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try ReaderModel(root: directory)
        await model.load()
        let block = TextBlock(sourcePage: 0, text: "Original evidence.")
        var paper = Paper(
            title: "Chinese note fixture", digest: "chinese-note", originalPath: "unused.pdf", pageCount: 1,
            blocks: [block], warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            [BilingualBlock(block: block, translation: String(repeating: "中文跨行证据包含不同文字与标点。", count: 10))],
            to: nil, paper: paper, root: directory)
        model.state.papers = [paper]
        #expect(await model.save())
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await noteWait { (try? await noteJS(web, "return !!window.paperNotes")) as? Bool == true }
        _ = try await noteJS(
            web,
            #"""
            window.section=document.querySelector('section');window.cn=section.querySelector('.translation');
            cn.firstChild.data='\n  '+cn.textContent+'\n';window.before=section.innerHTML;
            paperSelection.highlights([{key:section.dataset.key,text:'Original evidence.',range:[0,18],sourceOnly:true}]);
            window.initialLines=[...CSS.highlights.get('saved')].filter(r=>r.startContainer===cn.firstChild);
            window.initialBoxes=initialLines.flatMap(r=>[...r.getClientRects()]).filter(r=>r.width>.01&&r.height>0).map(r=>({left:r.left,top:r.top+scrollY,width:r.width,height:r.height}));
            window.r=document.createRange();r.setStart(cn.firstChild,3);r.setEnd(cn.firstChild,5);window.box=r.getBoundingClientRect();
            window.clickAt=(x,y)=>{cn.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:x,clientY:y}));cn.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:x,clientY:y}));};
            clickAt(box.left-2,(box.top+box.bottom)/2);
            """#)
        #expect(try await noteJS(web, "return paperNotes.editing()") as? Bool == false)
        #expect(
            try await noteJS(
                web,
                #"""
                const painted=[...document.querySelectorAll('#reader-annotation-backgrounds span')];
                return initialLines.length>3 && initialLines.every(r=>[...r.getClientRects()].filter(b=>b.width>.01&&b.height>0).length===1)
                  && initialBoxes.every(b=>painted.some(e=>['left','top','width','height'].every(k=>Math.abs(parseFloat(e.style[k])-b[k])<.5)));
                """#
            ) as? Bool == true)
        _ = try await noteJS(web, "clickAt(box.left+2,(box.top+box.bottom)/2)")
        try await noteWait {
            (try? await noteJS(web, "return document.querySelectorAll('#reader-note-lift span').length>0")) as? Bool
                == true
        }
        #expect(
            try await noteJS(web, "return paperSelection.parts().every(p=>p.target==='translation')") as? Bool == true)
        #expect(
            try await noteJS(
                web,
                #"""
                const spans=[...document.querySelectorAll('#reader-note-lift span')];
                const backgrounds=[...document.querySelectorAll('.note-lift-highlight')];
                return backgrounds.length===initialBoxes.length && backgrounds.every((e,i)=>['left','top','width','height'].every(k=>Math.abs(parseFloat(e.style[k])-initialBoxes[i][k])<.5))
                    && section.innerHTML===before && spans.every(s=>!s.textContent.includes('\n') && getComputedStyle(s).fontFamily===getComputedStyle(cn).fontFamily && parseFloat(s.style.lineHeight)<parseFloat(getComputedStyle(cn).lineHeight))
                    && Math.abs(parseFloat(spans[0].style.top)-box.top-scrollY)<1;
                """#) as? Bool == true)
        _ = try await noteJS(web, "paperNotes.finish()")
        try await noteWait {
            (try? await noteJS(web, "return !document.querySelector('.note-lift-group')")) as? Bool == true
        }
        // The reported case ends partway through a line while the remaining highlight continues below.
        _ = try await noteJS(
            web,
            #"""
            window.cut=initialLines[3].startOffset+5;
            paperSelection.restore([{key:section.dataset.key,target:'translation',start:3,end:cut,text:cn.textContent.slice(3,cut)}]);paperNotes.begin();
            """#)
        try await noteWait {
            (try? await noteJS(web, "return !!document.querySelector('.note-lift-highlight')")) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                #"""
                const rest=[...CSS.highlights.get('saved')].filter(r=>r.startContainer===cn.firstChild);
                const lifted=[...document.querySelectorAll('.note-lift-highlight')];
                const tail=rest[0].getBoundingClientRect(),last=lifted.at(-1);
                return rest[0].startOffset===cut && lifted.length===4
                  && rest.every(r=>[...r.getClientRects()].filter(b=>b.width>.01&&b.height>0).length===1)
                  && Math.abs(parseFloat(last.style.left)+parseFloat(last.style.width)-tail.left)<.5
                  && Math.abs(parseFloat(last.style.top)-tail.top-scrollY)<.5
                  && Math.abs(parseFloat(last.style.height)-tail.height)<.5 && section.innerHTML===before;
                """#) as? Bool == true)
        _ = try await noteJS(web, "paperNotes.finish()")
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

    @Test @MainActor func noteLiftTransfersOnlySelectedPaintAndRestoresItOnExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try ReaderModel(root: directory)
        await model.load()
        let block = TextBlock(sourcePage: 0, text: "Alpha beta gamma delta evidence.")
        var paper = Paper(
            title: "Lift fixture", digest: "lift", originalPath: "unused.pdf", pageCount: 1, blocks: [block],
            warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            [BilingualBlock(block: block, translation: "中文独立标记。")], to: nil, paper: paper, root: directory)
        model.state.papers = [paper]
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        web.frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await noteWait { (try? await noteJS(web, "return !!window.paperNotes")) as? Bool == true }
        _ = try await noteJS(
            web,
            #"""
            window.p=document.querySelector('section p');window.before=p.outerHTML;window.height=p.getBoundingClientRect().height;
            window.key=p.closest('section').dataset.key;
            window.marks=[{key,target:'source',text:p.textContent.slice(0,10),range:[0,10],color:'red',style:'highlight'},
              {key,target:'source',text:p.textContent.slice(10,20),range:[10,20],color:'blue',style:'underline'}];
            paperSelection.highlights(marks);
            window.note={id:'lift-note',anchors:[{key,target:'source',text:p.textContent.slice(3,14),start:3,end:14}],markdown:'A note',html:'<p>A note</p>'};
            paperNotes.sync([note]);paperNotes.open(note.id,true);
            """#)
        try await noteWait {
            (try? await noteJS(web, "return !!document.querySelector('.note-lift-underline')")) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                #"""
                const lifted=document.querySelector('.note-lift-group');window.group=lifted;
                const red=[...CSS.highlights.get('saved-red-highlight')];
                const blue=[...CSS.highlights.get('saved-blue-underline')];
                return red.length===1 && red[0].startOffset===0 && red[0].endOffset===3
                  && blue.length===1 && blue[0].startOffset===14 && blue[0].endOffset===20
                  && lifted.querySelector('.note-lift-highlight').style.background==='rgb(245, 170, 166)'
                  && lifted.querySelector('.note-lift-underline').style.background==='rgb(181, 213, 248)'
                  && !!lifted.querySelector('.note-lift-waves .note-wave')
                  && !!document.querySelector('#reader-note-decoration .note-wave[mask]')
                  && [...CSS.highlights.get('reader-selection')].length===0
                  && paperSelection.copyText()===note.anchors[0].text
                  && p.outerHTML===before && p.getBoundingClientRect().height===height;
                """#) as? Bool == true)
        // Changing the saved paint during editing updates the same moving unit, without replaying its lift.
        _ = try await noteJS(web, "marks[0].color='green';paperSelection.highlights(marks)")
        try await noteWait {
            (try? await noteJS(
                web,
                "return document.querySelector('.note-lift-highlight')?.style.background==='rgb(183, 219, 158)'"))
                as? Bool == true
        }
        #expect(try await noteJS(web, "return document.querySelector('.note-lift-group')===group") as? Bool == true)
        _ = try await noteJS(web, "paperNotes.finish()")
        try await noteWait {
            (try? await noteJS(web, "return !document.querySelector('.note-lift-group')")) as? Bool == true
        }
        #expect(
            try await noteJS(
                web,
                #"""
                const green=[...CSS.highlights.get('saved-green-highlight')],blue=[...CSS.highlights.get('saved-blue-underline')];
                return green[0].startOffset===0 && green[0].endOffset===10 && blue[0].startOffset===10 && blue[0].endOffset===20
                  && !CSS.highlights.has('note-lift') && !document.querySelector('.note-wave[mask]')
                  && !document.querySelector('#note-wave-cutouts') && p.outerHTML===before;
                """#) as? Bool == true)
        model.select(nil)
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
