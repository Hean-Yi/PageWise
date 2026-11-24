import SwiftUI

enum HTMLNotesScript {
    /// Only application-owned drawing instructions enter the reader's script.
    private static func iconPath(_ path: Path) -> String {
        func point(_ p: CGPoint) -> String { "\(p.x) \(p.y)" }
        var commands: [String] = []
        func append(_ element: Path.Element) {
            switch element {
            case .move(let to): commands.append("M\(point(to))")
            case .line(let to): commands.append("L\(point(to))")
            case .quadCurve(let to, let control): commands.append("Q\(point(control)) \(point(to))")
            case .curve(let to, let first, let second):
                commands.append("C\(point(first)) \(point(second)) \(point(to))")
            case .closeSubpath: commands.append("Z")
            }
        }
        path.forEach(append)
        return commands.joined(separator: " ")
    }

    private static func iconSVG(_ glyph: ReaderIcon.Glyph) -> String {
        let plate = iconPath(glyph.inkPlate)
        let outline = iconPath(glyph.drawing)
        let hover = glyph.inkPose(for: .hovered)
        let press = glyph.inkPose(for: .pressed)
        func transform(_ pose: ReaderIconInkPose) -> String {
            "translate(\(pose.x)px,\(pose.y)px) rotate(\(pose.degrees)deg) scale(\(pose.scaleX),\(pose.scaleY))"
        }
        let poses =
            "--ink-hover:\(transform(hover));--ink-press:\(transform(press));"
            + "transform-origin:\(hover.pivotX)px \(hover.pivotY)px"
        return """
            <svg aria-hidden="true" focusable="false" width="16" height="16" viewBox="0 0 24 24"><path class="ink-plate" style="\(poses)" d="\(plate)"/><path d="\(outline)" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="square" stroke-linejoin="round"/></svg>
            """
    }

    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection,layout=window.paperNoteLayout,menu=document.getElementById('annotation-menu');
          const layer=document.createElement('div');layer.id='reader-note-layer';document.body.append(layer);
          const records=new Map();let active=null,editing=null,sidebar=true,reverse=false,queued=false,restingDirty=true,displayed=null,pointer=null,lastStatus='已保存';
          const send=v=>window.webkit.messageHandlers.reader.postMessage({...v,paperID:document.body.dataset.paperId});
          const normalize=a=>a.map(p=>({key:p.key,target:p.target,text:p.text,start:p.start??p.range?.[0],end:p.end??p.range?.[1]}));
          const same=(a,b)=>JSON.stringify(normalize(a))===JSON.stringify(normalize(b));
          const body=e=>{if(e.html){e.content.innerHTML=e.html;e.content.style.whiteSpace='normal';}else {e.content.textContent=e.markdown||'点击添加笔记';e.content.style.whiteSpace='pre-wrap';}e.summary.textContent=e.html?[...e.content.children].map(n=>n.textContent).join(' '):e.markdown||'点击添加笔记';};
          const undock=()=>{if(menu.classList.contains('note-docked')){document.body.append(menu);menu.classList.remove('note-docked');menu.hidden=true;}};
          const flush=()=>send({kind:'noteFlush'});
          const store=e=>{e.markdown=e.input.value;e.html='';e.status.textContent='保存中…';send({kind:'noteChange',id:e.id,anchors:e.anchors,markdown:e.markdown});};
          const finish=()=>{
            closeChoices();
            const e=records.get(editing);if(e){e.emergeAnimation?.cancel();e.entrance=false;if(e.input.value!==e.markdown)store(e);e.card.classList.remove('editing-live');e.input.classList.add('note-hidden');e.footer.classList.add('note-hidden');e.content.classList.remove('note-hidden');e.tabs.classList.add('note-hidden');body(e);flush();}
            if(e?.card.contains(document.activeElement))document.activeElement.blur();
            if(e)selection.editingChanged?.(e.id,false);
            editing=null;active=null;undock();selection.clear();
            if(e&&!e.markdown.trim()&&!e.persisted){e.editor?.destroy();e.card.remove();records.delete(e.id);}schedule();
          };
          const activate=(id,edit=false,backwards=false)=>{
            if(editing&&editing!==id){if(!edit)return;finish();}
            const e=records.get(id);if(!e)return;
            if(choiceOwner && choiceOwner!==e)closeChoices();
            if(!edit&&active===id){reverse=backwards;layout.reverse(backwards);return;}
            active=id;e.previewBox=null;reverse=backwards;
            if(edit){
              e.entrance=editing!==id;if(e.entrance)selection.editingChanged?.(id,true);e.needsFocus=true;editing=id;e.tabs.classList.remove('note-hidden');e.footer.classList.remove('note-hidden');e.card.classList.add('editing-live');e.input.classList.remove('note-hidden');e.content.classList.add('note-hidden');
              selection.restore(e.anchors);menu.classList.add('note-docked');e.card.prepend(menu);menu.hidden=false;window.paperAnnotationMenu.refresh();
              if(!e.editor)e.editor=PaperNoteEditor.create(e.input,e.markdown,()=>store(e),finish);
              e.input.value=e.markdown;if(e.html)e.editor.preview(e.markdown,e.html);e.input.focus({preventScroll:true});
            }
            schedule(false);
          };
          const leave=()=>{cancelCrossing();if(active&&!editing){active=null;schedule(false);}};
          const button=(text,handler,label=text)=>{const b=document.createElement('button');b.type='button';b.textContent=text;b.setAttribute('aria-label',label);b.onclick=event=>{event.stopPropagation();handler();};return b;};
          const choices=document.createElement('div');
          choices.id='reader-note-choices';choices.popover='manual';choices.setAttribute('role','menu');choices.setAttribute('aria-label','重叠笔记');
          let choiceOwner=null;
          const closeChoices=(refocus=false)=>{
            if(!choiceOwner)return;
            const trigger=choiceOwner.choices;choiceOwner=null;trigger.setAttribute('aria-expanded','false');
            if(choices.matches(':popover-open'))choices.hidePopover();
            if(refocus)trigger.focus({preventScroll:true});
          };
          choices.addEventListener('beforetoggle',event=>{if(event.newState==='closed'&&choiceOwner){choiceOwner.choices.setAttribute('aria-expanded','false');choiceOwner=null;}});
          const focusChoice=row=>{
            row.focus({preventScroll:true});
            if(row.offsetTop<choices.scrollTop)choices.scrollTop=row.offsetTop;
            else if(row.offsetTop+row.offsetHeight>choices.scrollTop+choices.clientHeight)choices.scrollTop=row.offsetTop+row.offsetHeight-choices.clientHeight;
          };
          const openChoices=e=>{
            if(choiceOwner===e){closeChoices(true);return;}
            closeChoices();
            const candidates=(e.choiceIDs||[]).map(id=>records.get(id)).filter(Boolean);
            if(candidates.length<2)return;
            const rows=candidates.map((item,i)=>{
              const title=(i+1)+' · '+(item.dimensionTitle||'笔记');
              const excerpt=item.summary.textContent.replace(/\s+/g,' ').trim().slice(0,75);
              const row=button(title,()=>{
                const edit=!!editing;closeChoices();activate(item.id,edit,true);
                if(!edit){item.focusChoices=true;schedule(false);}
              },excerpt?title+'，'+excerpt:title);
              row.setAttribute('role','menuitemradio');row.setAttribute('aria-checked',String(item.id===e.id));row.tabIndex=-1;
              if(excerpt){const small=document.createElement('small');small.textContent=excerpt;row.append(small);}
              return row;
            });
            choices.replaceChildren(...rows);e.card.append(choices);choiceOwner=e;e.choices.setAttribute('aria-expanded','true');
            choices.style.removeProperty('max-height');choices.showPopover();
            const anchor=e.choices.getBoundingClientRect(),box=choices.getBoundingClientRect(),gap=6,edge=8;
            const below=innerHeight-anchor.bottom-edge-gap,above=anchor.top-edge-gap;
            const down=box.height<=below||below>=above,height=Math.max(1,Math.min(box.height,down?below:above));
            choices.style.maxHeight=height+'px';
            choices.style.left=Math.max(edge,Math.min(anchor.left,innerWidth-box.width-edge))+'px';
            choices.style.top=(down?anchor.bottom+gap:anchor.top-gap-height)+'px';
            focusChoice(rows[candidates.indexOf(e)]);
          };
          choices.addEventListener('keydown',event=>{
            const rows=[...choices.children],index=rows.indexOf(document.activeElement);
            if(event.key==='Escape'){event.preventDefault();event.stopPropagation();closeChoices(true);return;}
            if(event.key==='Tab'){closeChoices(true);return;}
            if(event.key==='Enter'||event.key===' '){event.preventDefault();event.stopPropagation();rows[index]?.click();return;}
            const next={ArrowDown:(index+1)%rows.length,ArrowUp:(index-1+rows.length)%rows.length,Home:0,End:rows.length-1}[event.key];
            if(next!==undefined){event.preventDefault();event.stopPropagation();focusChoice(rows[next]);}
          });
          const choiceTrigger=e=>{
            const b=button('',()=>openChoices(e),'切换重叠笔记');b.className='note-choice-trigger note-hidden';
            b.setAttribute('aria-haspopup','menu');b.setAttribute('aria-expanded','false');b.setAttribute('aria-controls',choices.id);
            b.onkeydown=event=>{if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();openChoices(e);}};
            return b;
          };
          const icons={source:'\#(iconSVG(.source))',citation:'\#(iconSVG(.citation))',delete:'\#(iconSVG(.delete))'};
          const reduceIconMotion=matchMedia('(prefers-reduced-motion:reduce)');
          const iconButton=(icon,label,handler)=>{
            let release;
            const b=button('',()=>{
              if(!reduceIconMotion.matches){
                release?.cancel();
                release=plate.animate([{transform:'var(--ink-press)'},{transform:'var(--ink-rest, none)'}],
                  {duration:190,easing:'cubic-bezier(.2,.8,.3,1)'});
              }
              handler();
            },label);
            b.title=label;b.className='note-icon-button';
            b.innerHTML=icons[icon];
            const plate=b.querySelector('.ink-plate');
            b.onpointerdown=()=>release?.cancel();
            b.onkeydown=event=>{
              if(event.key===' '||event.key==='Enter'){release?.cancel();b.dataset.keyPress='';}
            };
            b.onkeyup=b.onblur=()=>{delete b.dataset.keyPress;};
            return b;
          };
          const scrollToAnchor=anchors=>{
            const first=anchors[0],target=selection.rangesFor(first)[0];
            const node=document.getElementById('block-'+first.key)||target?.startContainer?.parentElement;
            node?.scrollIntoView({block:'center',inline:'nearest'});
          };
          const make=note=>{
            const e={...note,persisted:false};e.card=document.createElement('article');e.card.className='reader-note-card';e.card.hidden=true;e.card.dataset.noteId=e.id;e.card.tabIndex=0;e.card.setAttribute('aria-label',e.dimensionTitle||'阅读笔记');
            const header=document.createElement('header'),title=document.createElement('strong');title.textContent=e.dimensionTitle||'笔记';header.append(title);
            e.choices=choiceTrigger(e);header.append(e.choices);
            e.tabs=document.createElement('span');e.tabs.className='note-hidden';
            e.tabs.textContent='Markdown';header.append(e.tabs);
            header.append(iconButton('source','定位笔记原文',()=>{scrollToAnchor(e.anchors);schedule();}));
            header.append(iconButton('delete','删除笔记',()=>{const id=e.id;finish();send({kind:'noteDelete',id});e.editor?.destroy();e.card.remove();records.delete(id);showUndo();schedule();}));
            e.input=document.createElement('div');e.input.className='note-editor note-hidden';
            e.input.oninput=event=>{if(event.target===e.input)store(e);};
            e.input.onkeydown=event=>{if((event.metaKey||event.ctrlKey)&&event.key==='Enter'){event.preventDefault();finish();}if(event.key==='Escape'){event.preventDefault();event.stopPropagation();finish();}};
            e.summary=document.createElement('div');e.summary.className='note-summary';
            e.content=document.createElement('div');e.content.className='note-content';e.content.setAttribute('aria-label','笔记预览');
            PaperNoteEditor.bindPassages(e.card,passage=>send({kind:'notePreviewPassage',id:e.id,passage}));
            e.footer=document.createElement('footer');e.footer.className='note-hidden';e.status=document.createElement('button');e.status.type='button';e.status.textContent=lastStatus;e.status.onclick=flush;
            const insert=iconButton('citation','引用阅读笔记',()=>{
              if(editing!==e.id||!e.editor)return;
              send({kind:'noteInsertPassage',id:e.id,anchors:e.anchors,markdown:e.input.value,from:e.editor.selectionStart,to:e.editor.selectionEnd});
            });
            const done=button('完成',finish);done.className='note-done';e.footer.append(e.status,insert,done);e.card.append(header,e.input,e.content,e.summary,e.footer);
            e.card.addEventListener('mouseenter',()=>{cancelCrossing();if(!choiceOwner&&!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('focusin',()=>{if(!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('click',event=>{if(event.target.closest('button,.note-editor,a,summary,#reader-note-choices,#annotation-menu'))return;if(editing!==e.id)activate(e.id,true,true);});
            e.card.addEventListener('keydown',event=>{if(event.target===e.card&&(event.key==='Enter'||event.key===' ')){event.preventDefault();activate(e.id,true,true);}});
            body(e);layer.append(e.card);records.set(e.id,e);return e;
          };
          const showUndo=()=>{let b=document.getElementById('reader-note-undo');if(!b){b=button('笔记已删除 · 撤销',()=>{send({kind:'noteUndo'});b.remove();});b.id='reader-note-undo';document.body.append(b);}};
          const bySection=new Map(),sectionKey=a=>selection.sectionKey?.(a)??a.key;
          const show=(e,position,documentTop)=>{
            e.card.hidden=!position;if(!position)return;
            e.card.classList.toggle('compact',position.height<300);e.card.dataset.placement=position.side;
            e.card.classList.toggle('at-top',position.clip==='top');e.card.classList.toggle('at-bottom',position.clip==='bottom');
            Object.assign(e.card.style,{position:position.fixed?'fixed':'absolute',left:position.left+'px',top:documentTop+'px',
              width:position.width+'px',height:position.height+'px',maxHeight:position.height+'px'});
          };
          const restoreSlot=e=>{
            e.previewBox=null;e.card.classList.remove('active');show(e,e.slot,e.slot?.top);
          };
          const arrangeSlots=()=>{
            bySection.clear();const occupied=[];
            const index=new Map([...root.querySelectorAll('[data-key]')].map((s,i)=>[s.dataset.key,i]));
            const items=[...records.values()].sort((a,b)=>(index.get(sectionKey(a.anchors[0]))??Infinity)-(index.get(sectionKey(b.anchors[0]))??Infinity));
            for(const e of items){
              for(const key of new Set(e.anchors.map(sectionKey))){if(!bySection.has(key))bySection.set(key,[]);bySection.get(key).push(e);}
              const slot=sidebar?null:layout.place(e.anchors,168,false,occupied,true);
              if(slot)occupied.push(slot);
              e.slot=slot?{...slot,top:slot.top+scrollY}:null;
              if(e.id!==active)restoreSlot(e);
            }
            layout.rebuildWaves(items);
          };
          const arrange=()=>{
            queued=false;const entry=records.get(active);
            if(restingDirty){restingDirty=false;arrangeSlots();}
            else if(displayed&&displayed!==entry)restoreSlot(displayed);
            displayed=entry;
            let position=null;
            if(entry){
              const e=entry,isEditor=editing===e.id;
              e.card.classList.add('active');
              const measure=width=>{
                e.card.hidden=false;e.card.style.width=width+'px';e.card.style.height='auto';e.card.style.maxHeight='none';
                return Math.max(e.slot?168:100,e.card.offsetHeight);
              };
              const slot=e.slot,top=slot?slot.top-scrollY:0;
              // A clipped margin card keeps every visible pixel of its resting hit target.
              // Its text anchor may already have scrolled completely out of view.
              if(!isEditor&&slot&&top<innerHeight&&top+slot.height>0){
                const clipped=top<0||top+slot.height>innerHeight;
                const height=Math.min(measure(slot.width),420,clipped?innerHeight:innerHeight-top);
                const previewTop=clipped?Math.max(0,Math.min(top,innerHeight-height)):top;
                position={...slot,top:previewTop,height,clip:clipped?(top<0?'top':'bottom'):null};
              }else{
                position=layout.place(e.anchors,isEditor?420:measure,sidebar,[]);
                if(!position&&isEditor)position={left:Math.max(16,innerWidth-366),top:16,width:350,height:Math.min(420,innerHeight-32),side:'floating'};
              }
              if(position){
                position.fixed=isEditor;
                const documentTop=position.top+(isEditor?0:scrollY);
                show(e,position,documentTop);
                e.previewBox=isEditor?null:{left:position.left,top:documentTop,right:position.left+position.width,bottom:documentTop+position.height,side:position.side};
              }else{restoreSlot(e);active=null;displayed=null;}
            }
            const opening=!!entry?.entrance;
            layout.decorate(displayed,position,opening?false:reverse,opening);
            if(opening&&position){entry.entrance=false;emerge(entry,position);}
            if(entry?.needsFocus&&position){entry.needsFocus=false;entry.input.focus({preventScroll:true});}
            if(entry?.focusChoices&&position){entry.focusChoices=false;entry.choices.focus({preventScroll:true});}
            const crossing=pendingCrossing;pendingCrossing=null;
            if(crossing&&entry?.id===crossing.id&&!editing)cross(entry,crossing.x,crossing.y,crossing.previous);
          };
          const emerge=(e,position)=>{
            e.emergeAnimation?.cancel();
            if(matchMedia('(prefers-reduced-motion:reduce)').matches){layout.endEntrance(e.id);return;}
            const point=layout.connectionEnd(),floating=position.side==='floating';
            const x=point?point.x-position.left:position.width/2,y=point?point.y-position.top:0;
            e.card.style.transformOrigin=Math.max(0,Math.min(position.width,x))+'px '+Math.max(0,Math.min(position.height,y))+'px';
            e.card.style.willChange='transform,opacity';
            const animation=e.card.animate([
              {transform:'translateY(-2px) scale('+(floating?'.12,.08':'.88,.76')+')',opacity:floating?0:.85,offset:0},
              {transform:'translateY(-2px) scale(1.035,.975)',opacity:1,offset:.55},
              {transform:'translateY(-2px) scale(.988,1.015)',opacity:1,offset:.79},
              {transform:'translateY(-2px) scale(1,1)',opacity:1,offset:1}
            ],{duration:360,delay:floating?80:40,fill:'backwards',easing:'cubic-bezier(.22,.7,.25,1)'});
            e.emergeAnimation=animation;animation.id='note-emerge';
            const release=()=>{if(e.emergeAnimation!==animation)return;e.card.style.willChange='';e.card.style.transformOrigin='';e.emergeAnimation=null;layout.endEntrance(e.id);};
            animation.finished.then(release,release);
          };
          function schedule(full=true){
            if(full)restingDirty=true;
            if(queued)return;queued=true;
            const run=()=>{cancelAnimationFrame(frame);clearTimeout(timer);arrange();};
            const frame=requestAnimationFrame(run),timer=setTimeout(run,32);
          }
          const begin=()=>{
            const anchors=normalize(selection.parts());if(!anchors.length)return;
            const existing=[...records.values()].find(e=>same(e.anchors,anchors));
            const e=existing||make({id:crypto.randomUUID().toUpperCase(),anchors,markdown:'',html:''});activate(e.id,true);
          };
          const hits=(target,x,y,precise=false)=>(bySection.get(target.closest?.('[data-key]')?.dataset.key)||[]).filter(e=>layout.hit(e.anchors,x,y,precise));
          const setChoices=matches=>{
            const ids=matches.map(e=>e.id);
            for(const [index,e] of matches.entries()){
              if(e.choiceIDs?.length===ids.length&&ids.every((id,i)=>e.choiceIDs[i]===id))continue;
              e.choiceIDs=ids;e.choices.classList.toggle('note-hidden',ids.length<2);
              e.choices.textContent=(index+1)+' / '+ids.length;
              e.choices.setAttribute('aria-label','切换重叠笔记，当前第 '+(index+1)+' 条，共 '+ids.length+' 条');
            }
          };
          document.addEventListener('pointerdown',event=>{
            if(choiceOwner&&!choices.contains(event.target)&&!choiceOwner.choices.contains(event.target))closeChoices();
            pointer={x:event.clientX,y:event.clientY};
            if(appendixEditor?.editor && !appendix.contains(event.target))appendixEditor.finish();
            if(event.target.closest('.reader-note-card,#annotation-menu'))return;
            if(editing)finish();
          },true);
          root.addEventListener('click',event=>{
            if(!pointer||Math.hypot(event.clientX-pointer.x,event.clientY-pointer.y)>4||!getSelection().isCollapsed)return;
            const matches=hits(event.target,event.clientX,event.clientY,true);setChoices(matches);
            if(matches.length){event.preventDefault();event.stopImmediatePropagation();activate(matches[0].id,true);return;}
            for(const mark of selection.projectedMarks()){
              const parts=normalize(mark.parts.map(p=>({...p,key:mark.key})));
              const hit=parts.find(p=>layout.hit([p],event.clientX,event.clientY,true));if(!hit)continue;
              // Clicking a legacy bilingual mark edits only the language actually clicked.
              const anchors=parts.filter(p=>p.target===hit.target);
              event.preventDefault();event.stopImmediatePropagation();
              const e=make({id:crypto.randomUUID().toUpperCase(),anchors,markdown:'',html:''});activate(e.id,true);return;
            }
          },true);
          let pendingCrossing=null,crossingTimer=null,lastPoint=null,scrollCheck=false;
          const cancelCrossing=()=>{clearTimeout(crossingTimer);crossingTimer=null;pendingCrossing=null;};
          const cross=(e,x,y,previous)=>{
            if(!layout.inBridge(e.anchors,e.previewBox,x,y)){leave();return;}
            if(e.previewBox?.side==='floating')return;
            // The gap is only a passage. Resting over unmarked prose always releases it.
            const direction=(e.previewBox.side==='right'?1:-1)*(reverse?-1:1);
            if(previous&&(x-previous.x)*direction < -2){leave();return;}
            if(!crossingTimer||previous&&(x-previous.x)*direction>0){
              clearTimeout(crossingTimer);crossingTimer=setTimeout(leave,160);
            }
          };
          const track=(target,x,y,previous,scrolled=false)=>{
            const card=target?.closest?.('.reader-note-card');
            if(card){cancelCrossing();if(active!==card.dataset.noteId||!reverse)activate(card.dataset.noteId,false,true);return;}
            const matches=target?hits(target,x,y):[];
            if(matches.length){
              cancelCrossing();
              const e=matches.find(m=>m.id===active)||matches[0];
              setChoices(matches);
              if(active!==e.id){activate(e.id);}
              else if(reverse){reverse=false;layout.reverse(false);}
              return;
            }
            const e=records.get(active);
            if(!e||scrolled){leave();return;}
            if(!e.previewBox&&queued){pendingCrossing={id:e.id,x,y,previous};return;}
            cross(e,x,y,previous);
          };
          document.addEventListener('pointermove',event=>{
            if(choiceOwner||editing||appendixEditor?.editor||event.buttons||event.pointerType==='touch')return;
            const x=event.clientX,y=event.clientY,previous=lastPoint;lastPoint={x,y};track(event.target,x,y,previous);
          });
          document.addEventListener('mouseleave',()=>{lastPoint=null;if(!choiceOwner)leave();});
          document.addEventListener('keydown',event=>{if(event.key==='Escape'&&active)finish();});
          const resized=()=>{closeChoices();layout.invalidate();schedule();};
          window.addEventListener('resize',resized);
          document.addEventListener('scroll',()=>{
            closeChoices();
            layout.scrolled();
            if(lastPoint&&!editing&&!scrollCheck){scrollCheck=true;requestAnimationFrame(()=>{
              scrollCheck=false;if(!lastPoint||editing)return;
              const {x,y}=lastPoint;track(document.elementFromPoint(x,y),x,y,null,true);
            });}
          },{passive:true});
          new ResizeObserver(resized).observe(root);document.fonts?.ready.then(resized);document.fonts?.addEventListener('loadingdone',resized);
          // The appendix follows the published reader; it never becomes a paper section or an annotation anchor.
          let appendix=null,appendixEditor=null;
          const summary=(id,source,html)=>{
            if(appendix && appendix.dataset.noteId!==id){
              appendixEditor.destroy();appendix.remove();appendix=null;appendixEditor=null;
            }
            if(!id)return;
            if(!appendix){
              appendix=document.createElement('article');appendix.id='reader-document-summary';appendix.lang='zh-Hans';
              appendix.dataset.noteId=id;appendix.setAttribute('aria-label','文末总结');
              const head=document.createElement('header'),title=document.createElement('strong');title.textContent='文末总结';
              const tools=document.createElement('span');
              const retry=button('保存失败，重试',flush,'重试保存阅读笔记');
              retry.hidden=!lastStatus.startsWith('保存失败');
              tools.append(retry,iconButton('citation','引用阅读笔记',()=>{
                const e=appendixEditor.editForCitation();
                if(e)send({kind:'noteInsertPassage',id,anchors:[],markdown:e.value,from:e.selectionStart,to:e.selectionEnd});
              }));
              head.append(title,tools);
              const prose=document.createElement('div');prose.className='note-prose';appendix.append(head,prose);root.after(appendix);
              appendixEditor=PaperNoteEditor.attachSummary(prose,markdown=>send({kind:'noteChange',id,anchors:[],markdown}),active=>{
                if(!active)flush();
              });
              PaperNoteEditor.bindPassages(appendix,passage=>send({kind:'notePreviewPassage',id,passage}));
            }
            appendixEditor.update(source,html);
          };
          window.paperNotes={
            summary,
            openDraft(note){
              if(!note.anchors?.some(a=>selection.rangesFor(a).length))return;
              const e=records.get(note.id)||make(note);
              if(editing!==e.id)activate(e.id,true);
            },
            begin:selection.beginNote??begin,editing:()=>!!editing||!!appendixEditor?.editor,preservingSelection:()=>!!editing||!!appendixEditor?.editor,
            sidebar(open){if(sidebar!==open){sidebar=open;resized();}},
            sync(notes){
              let changed=false;const ids=new Set(notes.map(n=>n.id));
              for(const [id,e] of records)if(e.persisted&&!ids.has(id)&&editing!==id){e.editor?.destroy();e.card.remove();records.delete(id);changed=true;}
              for(const note of notes){let e=records.get(note.id);if(!e){e=make(note);changed=true;}e.persisted=true;
                if(editing===e.id)continue;
                if(e.anchors!==note.anchors&&!same(e.anchors,note.anchors)){e.anchors=note.anchors;changed=true;}
                const markdownChanged=e.markdown!==note.markdown;
                if(markdownChanged||note.html&&note.html!==e.html){
                  e.markdown=note.markdown;e.html=note.html||'';body(e);changed=true;
                }
              }if(changed)schedule();
            },
            preview(id,source,html){if(appendix?.dataset.noteId===id){appendixEditor.update(source,html);return;}const e=records.get(id);if(!e||e.markdown!==source)return;e.html=html;e.content.style.whiteSpace='normal';body(e);e.editor?.preview(source,html);if(active===id&&!editing)schedule(false);},
            previewError(id){const e=records.get(id);if(e){e.content.textContent=e.markdown;e.status.textContent='预览失败，源码已保留';}},
            saved(status){lastStatus=status;for(const e of records.values())e.status.textContent=status;
              const retry=appendix?.querySelector('button[aria-label="重试保存阅读笔记"]');if(retry)retry.hidden=!status.startsWith('保存失败');},
            insertPassage(id,source,from,to,markdown){
              if(appendix?.dataset.noteId===id)return appendixEditor.editor?.insertPassage(source,from,to,markdown);
              return editing===id&&records.get(id)?.editor?.insertPassage(source,from,to,markdown);},
            open(id,edit,reveal=true){const e=records.get(id);if(!e)return false;if(reveal)scrollToAnchor(e.anchors);activate(id,edit);return true;},
            reset(){
              if(editing)finish();else selection.clear();
              closeChoices();cancelCrossing();
              for(const e of records.values()){e.emergeAnimation?.cancel();e.editor?.destroy();e.card.remove();}
              records.clear();bySection.clear();active=null;displayed=null;pointer=null;lastPoint=null;
              document.getElementById('reader-note-undo')?.remove();
              window.paperNoteLift.clear();layout.invalidate();schedule();
            },
            finish,layout:schedule
          };
        })();
        """#
}
