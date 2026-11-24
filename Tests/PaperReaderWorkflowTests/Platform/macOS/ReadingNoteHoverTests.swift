#if os(macOS)
    import PaperReaderKit
    import Testing
    import WebKit
    @testable import PaperReaderUI

    @MainActor private func withNoteHoverReader(
        width: CGFloat, blockCount: Int = 1, check: @MainActor (WKWebView) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ReaderModel(root: root)
        await model.load()
        let text = String(repeating: "We compare the same capacity on the held-out validation set. ", count: 5)
        let blocks = (0..<blockCount).map { TextBlock(sourcePage: $0, text: text) }
        var paper = Paper(
            title: "Hover fixture", digest: "hover", originalPath: "unused.pdf", pageCount: blockCount, blocks: blocks,
            warnings: [], canReflow: true)
        paper.htmlReading = try await HTMLReadingStore().append(
            blocks.map { BilingualBlock(block: $0, translation: "比较相同容量下的验证结果。") },
            to: nil, paper: paper, root: root)
        model.state.papers = [paper]
        model.select(paper.id)
        let coordinator = HTMLCoordinator(model: model)
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        coordinator.update(web)
        for _ in 0..<300 {
            if (try? await web.evaluateJavaScript("!!window.paperNotes", in: nil, contentWorld: .defaultClient))
                as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await check(web)
    }

    @Test @MainActor func wrappedNoteHoverCanCrossToFloatingPreviewWithoutMovingIt() async throws {
        try await withNoteHoverReader(width: 1050) { web in
            @MainActor func run(_ script: String) async throws -> Any? {
                try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            }
            _ = try await run(NoteHoverFixture.install)
            web.frame.size.width = 700
            for direction in ["below", "above"] {
                let result = try await run("return await hoverFixture('\(direction)')") as? String
                #expect(result == "ok")
            }
            web.frame.size.width = 1500
            #expect(try await run("return await hoverMargin()") as? String == "ok")
        }
    }

    @Test @MainActor func marginNoteHoverTracksWrappedTextAndCardWithoutMeasuringOtherPages() async throws {
        try await withNoteHoverReader(width: 1500, blockCount: 12) { web in
            let failures = try await web.callAsyncJavaScript(
                MarginNoteHoverFixture.check, arguments: [:], in: nil, contentWorld: .defaultClient)
            #expect(failures as? [String] == [])
        }
    }

    @Test @MainActor func overlappingNoteMenuCanCancelAndSwitchWithTheKeyboard() async throws {
        try await withNoteHoverReader(width: 1050) { web in
            let checks = try await web.callAsyncJavaScript(
                #"""
                const section=document.querySelector('#reader section'),text=section.querySelector('p').firstChild;
                const anchor={key:section.dataset.key,target:'source',start:0,end:12,text:text.data.slice(0,12)};
                const notes=['first','second'].map(id=>({id,anchors:[anchor],markdown:id+' note'}));
                const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
                const key=(target,k)=>target.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true,cancelable:true}));
                paperNotes.sync(notes);await wait(110);
                const rect=paperNoteLayout.rects([anchor])[0],point={clientX:rect.left+3,clientY:(rect.top+rect.bottom)/2};
                text.parentElement.dispatchEvent(new PointerEvent('pointerdown',{...point,bubbles:true}));
                text.parentElement.dispatchEvent(new MouseEvent('click',{...point,bubbles:true}));
                await wait(110);
                const card=document.querySelector('.reader-note-card.active'),trigger=card.querySelector('.note-choice-trigger');
                if(card.dataset.noteId!=='first'||trigger.classList.contains('note-hidden')) return ['trigger'];
                trigger.click();
                const menu=card.querySelector('[role=menu]'),rows=menu.querySelectorAll('[role=menuitemradio]');
                const errors=[];
                if(!menu.matches(':popover-open')||rows.length!==2||rows[0].getAttribute('aria-checked')!=='true')errors.push('selected row');
                if(!rows[1].textContent.includes('second note'))errors.push('preview');
                key(rows[0],'ArrowDown');
                if(document.activeElement!==rows[1])errors.push('move focus');
                key(rows[1],'Escape');
                if(menu.matches(':popover-open')||document.activeElement!==trigger||!paperNotes.editing())errors.push('cancel in place');
                key(trigger,'ArrowDown');
                key(document.activeElement,'End');key(document.activeElement,'Enter');await wait(110);
                const active=document.querySelector('.reader-note-card.active');
                if(active.dataset.noteId!=='second'||active.querySelector('.note-editor').value!=='second note')errors.push('switch editor');
                if(document.querySelectorAll(':popover-open').length||!paperNotes.editing())errors.push('dismissed picker');
                return errors;
                """#,
                arguments: [:], in: nil, contentWorld: .defaultClient)
            #expect(checks as? [String] == [])
        }
    }

    enum NoteHoverFixture {
        static let install = #"""
            const root=document.getElementById('reader'),section=root.querySelector('section'),p=section.querySelector('p');
            const words=p.firstChild,anchor={key:section.dataset.key,target:'source',start:0,end:words.length,text:words.data};
            const next=section.querySelector('.translation'),nextText=next.firstChild;
            const other={key:section.dataset.key,target:'translation',start:0,end:nextText.length,text:nextText.data};
            root.style.maxWidth='660px';section.style.maxWidth='100%';document.body.style.minHeight='2200px';
            const spacer=document.createElement('div');root.before(spacer);
            paperNotes.sidebar(false);
            paperNotes.sync([{id:'hover',anchors:[anchor],markdown:('A concrete finding about the matched conditions. ').repeat(9)},
              {id:'other',anchors:[other],markdown:'A separate translation note.'}]);
            const wait=(ms=65)=>new Promise(done=>setTimeout(done,ms));
            const move=(x,y)=>{const target=document.elementFromPoint(x,y)||document;
              target.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x,clientY:y,pointerType:'mouse'}));};
            await wait(90);
            window.hoverMargin=async ()=>{
              move(0,0);spacer.style.height='0';root.style.width='660px';paperNotes.sidebar(false);window.scrollTo(0,0);
              paperNotes.sync(['one','two'].map(id=>({id,anchors:[anchor],markdown:'A short note on the same location.'})));
              await wait(100);
              const cards=[...document.querySelectorAll('.reader-note-card')].filter(n=>!n.hidden).sort((a,b)=>a.offsetTop-b.offsetTop);
              if(cards.length!==2||cards[1].offsetTop-cards[0].offsetTop<165)return 'no displaced resting slot';
              const card=cards[1],before=card.getBoundingClientRect();
              move(before.left+24,before.bottom-20);await wait();
              const after=card.getBoundingClientRect();
              if(!card.classList.contains('active')||Math.abs(before.top-after.top)>3
                ||!card.contains(document.elementFromPoint(before.left+24,before.bottom-20)))return 'margin slot moved';
              return 'ok';
            };
            window.hoverFixture=async direction=>{
              move(0,0);spacer.style.height=direction==='above'?'550px':'0px';
              root.style.width='min(440px,75vw)';paperNotes.sidebar(direction==='above');window.scrollTo(0,0);
              await wait(100);
              const range=document.createRange();range.selectNodeContents(p);
              const lines=[...range.getClientRects()].filter(r=>r.width>0);
              if(lines.length<3)return 'expected wrapped anchor';
              const last=lines.at(-1),first=lines[0],above=direction==='above';
              const line=above?first:last,start={x:line.left+line.width*.44,y:(line.top+line.bottom)/2};
              move(start.x,start.y);await wait();
              const card=document.querySelector('[data-note-id="hover"]');
              if(card.hidden||card.dataset.placement!=='floating')return 'preview did not open';
              const box=card.getBoundingClientRect();
              if(above?box.bottom>first.top:box.top<last.bottom)return 'unexpected side';
              const edge={x:box.right-16,y:above?box.bottom+2:box.top-2};
              const place=paperNoteLayout.place;let placements=0;
              paperNoteLayout.place=(...args)=>{placements++;return place(...args);};
              try{
                for(let step=1;step<=12;step++){
                  const t=step/12;move(start.x+(edge.x-start.x)*t,start.y+(edge.y-start.y)*t);
                  await wait(5);
                }
                move(edge.x,edge.y);await wait();
                if(card.hidden||!card.classList.contains('active'))return 'closed at card edge';
                move(edge.x,above?box.bottom-15:box.top+15);await wait();
                const arrived=card.getBoundingClientRect();
                if(card.hidden||arrived.top!==box.top||arrived.height!==box.height||placements)return 'moved during crossing';
                if(!card.contains(document.elementFromPoint(edge.x,above?box.bottom-15:box.top+15)))return 'card cannot receive pointer';
                const awayX=innerWidth-2;move(awayX,2);await wait();
                if(!card.hidden)return 'did not dismiss';
                const r=document.createRange();r.selectNodeContents(next);const b=r.getClientRects()[0];
                if(b.top>0&&b.bottom<innerHeight){
                  move(b.left+4,(b.top+b.bottom)/2);await wait();
                  if(!document.querySelector('[data-note-id="other"]').classList.contains('active'))return 'cannot switch notes';
                }
                return 'ok';
              }finally{paperNoteLayout.place=place;}
            };
            """#
    }
#endif
