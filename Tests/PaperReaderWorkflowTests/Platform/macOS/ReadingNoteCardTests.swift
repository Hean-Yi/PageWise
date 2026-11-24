#if os(macOS)
    import Foundation
    import PaperReaderKit
    import PaperReaderTestSupport
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
                for(const animation of card.getAnimations())animation.finish();
                const cardBox=card.getBoundingClientRect(),endpoint=document.querySelector('.note-link-end');
                const decoration=getComputedStyle(document.querySelector('#reader-note-decoration')),lift=getComputedStyle(document.querySelector('#reader-note-lift'));
                return Math.abs(Number(forward.split(' ')[2])-(anchor.top+anchor.bottom)/2)<.5
                  && Math.abs(Number(endpoint.getAttribute('cy'))-scrollY-(cardBox.top+cardBox.bottom)/2)<.5
                  && Math.abs(Number(endpoint.getAttribute('cx'))-cardBox.left)<.5
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
              {key,target:'source',text:p.textContent.slice(10,20),range:[10,20],color:'blue',style:'underline'},
              {key,target:'source',text:p.textContent.slice(21),range:[21,p.textContent.length],color:'purple'}];
            paperSelection.highlights(marks);
            const untouched=CSS.highlights.get('saved-purple-highlight'),fragment=[...untouched][0];
            const pixels=document.querySelector('#reader-annotation-backgrounds > div:last-child span');
            const cut=document.createRange();cut.setStart(p.firstChild,3);cut.setEnd(p.firstChild,14);
            const intact=()=>untouched===CSS.highlights.get('saved-purple-highlight')&&untouched.has(fragment)&&pixels.isConnected;
            paperSelection.liftRanges([cut]);window.keptUnrelatedPaint=intact();
            paperSelection.liftRanges([]);window.keptUnrelatedPaint&&=intact();
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
                return keptUnrelatedPaint && red.length===1 && red[0].startOffset===0 && red[0].endOffset===3
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

    @Test(arguments: [false, true]) @MainActor
    func insertingAndOpeningLibraryNotesUsesTheRealNoteEditor(pdf: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await model.load()
        let file = root.appendingPathComponent("evidence.pdf")
        try AttentionFixture.write(to: file)
        let target = try #require(await model.importURLs([file]).first)
        model.select(target)
        let document = try #require(model.paper)
        let quote = "Multiple attention heads"
        let passage = Evidence(id: "source", title: document.title, text: quote, paperID: target, sourcePage: 1)
        let memory = try await model.saveDiscussionNote(
            in: model.discussionNoteScope(for: target), sources: [(passage, quote)],
            markdown: "检索预算不同，比较时应按实际消耗分组。", requestID: UUID())
        let block = TextBlock(sourcePage: 0, text: "A reader can check the evidence.")
        let noteID = UUID()
        let web: WKWebView
        var pdfCoordinator: StandaloneReadingNoteEditor.Coordinator?
        var htmlCoordinator: HTMLCoordinator?
        if pdf {
            let fragments = try await PDFReadingNoteLocator().locate(quote: "Understanding", pageIndex: 0, in: file)
            let note = ReadingNote(
                id: noteID, paperID: target, contentVersion: "", anchors: fragments.map(\.anchor), markdown: "")
            let session = PDFNoteEditorSession(note: note, marks: [])
            model.pdfNoteEditor = session
            let coordinator = StandaloneReadingNoteEditor(model: model, note: session.note).makeCoordinator()
            pdfCoordinator = coordinator
            web = coordinator.makeView()
        } else {
            var paper = Paper(
                title: "A local reading", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
                blocks: [block], warnings: [], canReflow: true)
            paper.htmlReading = try await HTMLReadingStore().append(
                [BilingualBlock(block: block, translation: "证据")],
                to: nil, paper: paper, root: root)
            paper.translatedBlockCount = 1
            model.state.papers.append(paper)
            model.select(paper.id)
            model.openRetainedReading(nil)
            let anchor = NoteAnchor(key: block.id.uuidString, target: "source", text: "reader", start: 2, end: 8)
            try #require(model.updateReadingNote(id: noteID, anchors: [anchor], markdown: "A reference"))
            let coordinator = HTMLCoordinator(model: model)
            htmlCoordinator = coordinator
            web = coordinator.makeView()
            coordinator.update(web)
        }
        web.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        defer {
            pdfCoordinator?.stop()
            htmlCoordinator?.stop(web)
        }
        if pdf {
            try await noteWait { (try? await noteJS(web, "return !!window.pdfEditor")) as? Bool == true }
            pdfCoordinator?.updateCitationRequest(1, in: web)
        } else {
            try await noteWait {
                (try? await noteJS(web, "return !!document.querySelector('.reader-note-card')")) as? Bool == true
            }
            _ = try await noteJS(
                web,
                """
                paperNotes.open(id,true);
                const e=document.querySelector('.note-editor').noteEditor;e.setSelectionRange(2,11);
                document.querySelector('[aria-label="引用阅读笔记"]').click();
                """, ["id": noteID.uuidString])
        }
        try await noteWait { model.notePassageSheet != nil }
        guard case .picker(let draft) = model.notePassageSheet else {
            Issue.record("引用选择器未打开")
            return
        }
        let choices = try await model.readingNoteEvidence(query: "检索预算")
        let choice = try #require(choices.first { $0.readingNoteID == memory.id })
        try await model.insertNotePassage(choice, into: draft)
        try await noteWait {
            (try? await noteJS(web, "return !!document.querySelector('.cm-content a[data-passage]')")) as? Bool == true
        }
        let note = try #require(model.currentReadingNotes.first { $0.id == noteID })
        let citation = try #require(note.citations?.first)
        #expect(note.markdown.contains(citation.url.absoluteString))
        if !pdf { #expect(note.markdown.hasPrefix("A [reference](")) }
        // Exercise the down/up sequence on the live CodeMirror DOM. An editable mark can
        // disappear during mousedown, before click is ever dispatched to the link.
        for gesture in ["mouse", "touch", "keyboard"] {
            model.notePassageSheet = nil
            let stable = try await noteJS(
                web,
                """
                const e=document.querySelector('.note-editor').noteEditor;
                const a=e.view.contentDOM.querySelector('a[data-passage]');
                if(!a || a.isContentEditable || a.tabIndex!==0) return false;
                const before=e.value, caret=e.selectionStart;
                if(gesture==='keyboard'){
                    a.focus();
                    a.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
                }else{
                    const rect=a.getBoundingClientRect(), event={bubbles:true,cancelable:true,
                        button:0,clientX:rect.left+rect.width/2,clientY:rect.top+rect.height/2};
                    a.dispatchEvent(new PointerEvent('pointerdown',{...event,pointerType:gesture,buttons:1}));
                    if(gesture==='mouse') a.dispatchEvent(new MouseEvent('mousedown',{...event,buttons:1}));
                    await new Promise(resolve=>setTimeout(resolve,20));
                    if(!a.isConnected || a!==e.view.contentDOM.querySelector('a[data-passage]') || e.selectionStart!==caret) return false;
                    a.dispatchEvent(new PointerEvent('pointerup',{...event,pointerType:gesture}));
                    if(gesture==='touch') a.dispatchEvent(new MouseEvent('mousedown',{...event,buttons:1}));
                    a.dispatchEvent(new MouseEvent('mouseup',event));
                    a.dispatchEvent(new MouseEvent('click',event));
                }
                return a.isConnected && e.value===before;
                """, ["gesture": gesture])
            try #require(stable as? Bool == true, "打开引用时编辑选区与链接应保持稳定：\(gesture)")
            try await noteWait {
                if case .preview = model.notePassageSheet { return true }
                return false
            }
        }
        model.notePassageSheet = nil
        let editable = try await noteJS(
            web,
            """
            const e=document.querySelector('.note-editor').noteEditor;
            const a=e.view.contentDOM.querySelector('a[data-passage]');
            const source=e.value;
            a.focus();a.dispatchEvent(new KeyboardEvent('keydown',{key:'F2',bubbles:true,cancelable:true}));
            const showingSource=!e.view.contentDOM.querySelector('a[data-passage]') && e.view.contentDOM.textContent.includes('paperreader://passage/');
            e.setSelectionRange(source.length,source.length);
            return showingSource && source===e.value && !!e.view.contentDOM.querySelector('a[data-passage]');
            """)
        #expect(editable as? Bool == true)
        #expect(model.notePassageSheet == nil)
        let preview = try await model.previewLocalPassage(noteID: note.id, citationID: citation.id)
        #expect(
            preview.noteMarkdown == memory.markdown && preview.readingNoteID == memory.id
                && preview.title == model.state.papers.first { $0.id == target }?.title)
        if !pdf {
            model.notePassageSheet = nil
            _ = try await noteJS(
                web, "paperNotes.finish();document.querySelector('.note-content a[data-passage]').click()")
            try await noteWait {
                if case .preview = model.notePassageSheet { return true }
                return false
            }
        }
        await model.flushReadingNotes()
        try await model.openLocalPassage(preview)
        #expect(model.selectedPaperID == target && model.visiblePage == 1 && model.pdfNoteEditor?.id == memory.id)
    }

    @Test @MainActor func documentSummaryFollowsTheHTMLPaperOutsideItsAnnotationLayer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try ReaderModel(root: directory)
        await model.load()
        let block = TextBlock(sourcePage: 0, text: "A paired comparison holds the budget fixed.")
        var paper = Paper(
            title: "Budget", digest: "budget", originalPath: "unused.pdf", pageCount: 1,
            blocks: [block], warnings: [], canReflow: true)
        let html = try await HTMLReadingStore().append(
            [BilingualBlock(block: block, translation: "这组对照固定了预算。")], to: nil, paper: paper, root: directory)
        paper.htmlReading = html
        paper.translatedBlockCount = 1
        let version = try #require(html.readingNoteVersion(digest: paper.digest))
        let markdown = """
            # Budget comparison

            ## 怎样比较？

            先检查两个实验的**计算预算**。

            > 现有对照支持哪种解释？

            1. 比较相同预算下的 $x^2$。
            2. 检查控制变量。

            | 条件 | 得分 |
            | --- | --- |
            | 等预算 | 42 |
            """
        var summary = ReadingNote(paperID: paper.id, contentVersion: version, anchors: [], markdown: markdown)
        summary.placement = .documentEnd
        model.state.papers = [paper]
        model.state.readingNotes = [summary]
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        coordinator.update(web)
        try await noteWait {
            (try? await noteJS(
                web, "return document.querySelector('#reader + #reader-document-summary h1')?.textContent")) as? String
                == "Budget comparison"
        }
        #expect(
            try await noteJS(
                web,
                "return document.querySelectorAll('#reader > section').length===1 && !document.querySelector('.reader-note-card')"
            ) as? Bool == true)
        web.frame = CGRect(x: 0, y: 0, width: 1100, height: 780)
        let verifyProse = """
            const note=document.querySelector('#reader-document-summary'),prose=note?.querySelector('.note-prose');
            return !!prose?.querySelector('h2') && !!prose.querySelector('blockquote p') && prose.querySelectorAll('ol li').length===2
                && !!prose.querySelector('math') && !!prose.querySelector('table td') && !!prose.querySelector('strong');
            """
        #expect(try await noteJS(web, verifyProse) as? Bool == true)
        #expect(
            try await noteJS(
                web,
                """
                const note=document.querySelector('#reader-document-summary .note-prose'),printed=document.querySelector('#reader section');
                const rect=note.getBoundingClientRect(),other=printed.getBoundingClientRect();
                return Math.abs(rect.left-other.left)<1 && Math.abs(rect.width-other.width)<1
                    && getComputedStyle(note).fontFamily===getComputedStyle(printed.querySelector('.translation')).fontFamily;
                """) as? Bool == true)
        for size in [nil, 19] as [Int?] {
            let standalone = StandaloneReadingNoteEditor(
                model: model, note: summary, readOnly: true, summaryPDFFontSize: size
            ).makeCoordinator()
            let view = standalone.makeView()
            defer { standalone.stop() }
            view.frame = web.frame
            try await noteWait { (try? await noteJS(view, verifyProse)) as? Bool == true }
            #expect(
                try await noteJS(
                    view,
                    """
                    const p=document.querySelector('.note-prose');
                    return !p.closest('.reader-note-card') && parseFloat(getComputedStyle(p).fontSize)===size;
                    """, ["size": size ?? 17]) as? Bool == true)
        }
        _ = try await noteJS(web, "document.querySelector('#reader-document-summary button').click()")
        try await noteWait { model.presentedDocumentSummary?.id == summary.id && model.editingDocumentSummary }
        #expect(model.updateDocumentSummary(id: summary.id, markdown: "**Edited**"))
        model.navigateToPage(0)
        #expect(model.presentedDocumentSummary == nil)
        coordinator.update(web)
        try await noteWait {
            (try? await noteJS(
                web, "return document.querySelector('#reader-document-summary p strong')?.textContent==='Edited'"))
                as? Bool == true
        }
        model.deleteReadingNote(summary.id)
        coordinator.update(web)
        try await noteWait {
            (try? await noteJS(web, "return !document.querySelector('#reader-document-summary')")) as? Bool == true
        }
        await model.flushReadingNotes()
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
