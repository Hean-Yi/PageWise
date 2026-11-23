import Foundation

enum HTMLNotesScript {
    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection,layout=window.paperNoteLayout,menu=document.getElementById('annotation-menu');
          const layer=document.createElement('div');layer.id='reader-note-layer';document.body.append(layer);
          const records=new Map();let active=null,editing=null,sidebar=true,reverse=false,queued=false,pointer=null,lastStatus='已保存';
          const send=v=>window.webkit.messageHandlers.reader.postMessage({...v,paperID:document.body.dataset.paperId});
          const normalize=a=>a.map(p=>({key:p.key,target:p.target,text:p.text,start:p.start??p.range?.[0],end:p.end??p.range?.[1]}));
          const same=(a,b)=>JSON.stringify(normalize(a))===JSON.stringify(normalize(b));
          const body=e=>{if(e.html){e.content.innerHTML=e.html;e.content.style.whiteSpace='normal';}else {e.content.textContent=e.markdown||'点击添加笔记';e.content.style.whiteSpace='pre-wrap';}e.summary.textContent=e.html?[...e.content.children].map(n=>n.textContent).join(' '):e.markdown||'点击添加笔记';};
          const undock=()=>{if(menu.classList.contains('note-docked')){document.body.append(menu);menu.classList.remove('note-docked');menu.hidden=true;}};
          const flush=()=>send({kind:'noteFlush'});
          const store=e=>{e.markdown=e.input.value;e.html='';e.status.textContent='保存中…';send({kind:'noteChange',id:e.id,anchors:e.anchors,markdown:e.markdown});};
          const finish=()=>{
            const e=records.get(editing);if(e){e.emergeAnimation?.cancel();e.entrance=false;if(e.input.value!==e.markdown)store(e);e.card.classList.remove('editing-live');e.input.classList.add('note-hidden');e.footer.classList.add('note-hidden');e.content.classList.remove('note-hidden');e.tabs.classList.add('note-hidden');body(e);flush();}
            if(e?.card.contains(document.activeElement))document.activeElement.blur();
            editing=null;active=null;undock();selection.clear();
            if(e&&!e.markdown.trim()&&!e.persisted){e.editor?.destroy();e.card.remove();records.delete(e.id);}schedule();
          };
          const activate=(id,edit=false,backwards=false)=>{
            if(editing&&editing!==id){if(!edit)return;finish();}
            const e=records.get(id);if(!e)return;
            if(!edit&&active===id){reverse=backwards;layout.reverse(backwards);return;}
            active=id;e.previewBox=null;reverse=backwards;
            if(edit){
              e.entrance=editing!==id;e.needsFocus=true;editing=id;e.tabs.classList.remove('note-hidden');e.footer.classList.remove('note-hidden');e.card.classList.add('editing-live');e.input.classList.remove('note-hidden');e.content.classList.add('note-hidden');
              selection.restore(e.anchors);menu.classList.add('note-docked');e.card.prepend(menu);menu.hidden=false;window.paperAnnotationMenu.refresh();
              if(!e.editor)e.editor=PaperNoteEditor.create(e.input,e.markdown,()=>store(e),finish);
              e.input.value=e.markdown;if(e.html)e.editor.preview(e.markdown,e.html);e.input.focus({preventScroll:true});
            }
            schedule();
          };
          const leave=()=>{if(active&&!editing){active=null;schedule();}};
          const button=(text,handler,label=text)=>{const b=document.createElement('button');b.type='button';b.textContent=text;b.setAttribute('aria-label',label);b.onclick=event=>{event.stopPropagation();handler();};return b;};
          const make=note=>{
            const e={...note,persisted:false};e.card=document.createElement('article');e.card.className='reader-note-card';e.card.hidden=true;e.card.dataset.noteId=e.id;e.card.tabIndex=0;e.card.setAttribute('aria-label',e.dimensionTitle||'阅读笔记');
            const header=document.createElement('header'),title=document.createElement('strong');title.textContent=e.dimensionTitle||'笔记';header.append(title);
            e.choices=document.createElement('select');e.choices.setAttribute('aria-label','重叠笔记');e.choices.className='note-hidden';e.choices.onchange=()=>activate(e.choices.value,!!editing);header.append(e.choices);
            e.tabs=document.createElement('span');e.tabs.className='note-hidden';
            e.tabs.textContent='Markdown';header.append(e.tabs);header.append(button('原文',()=>{document.getElementById('block-'+e.anchors[0].key)?.scrollIntoView({block:'center'});schedule();},'定位笔记原文'));
            const more=document.createElement('details'),summary=document.createElement('summary');summary.textContent='···';summary.setAttribute('aria-label','笔记更多操作');more.append(summary);
            more.append(button('删除笔记',()=>{const id=e.id;finish();send({kind:'noteDelete',id});e.editor?.destroy();e.card.remove();records.delete(id);showUndo();schedule();}));header.append(more);
            e.input=document.createElement('div');e.input.className='note-editor note-hidden';
            e.input.oninput=event=>{if(event.target===e.input)store(e);};
            e.input.onkeydown=event=>{if((event.metaKey||event.ctrlKey)&&event.key==='Enter'){event.preventDefault();finish();}if(event.key==='Escape'){event.preventDefault();event.stopPropagation();finish();}};
            e.summary=document.createElement('div');e.summary.className='note-summary';
            e.content=document.createElement('div');e.content.className='note-content';e.content.setAttribute('aria-label','笔记预览');
            PaperNoteEditor.bindPassages(e.card,passage=>send({kind:'notePreviewPassage',id:e.id,passage}));
            e.footer=document.createElement('footer');e.footer.className='note-hidden';e.status=document.createElement('button');e.status.type='button';e.status.textContent=lastStatus;e.status.onclick=flush;
            const insert=button('引用笔记',()=>{
              if(editing!==e.id||!e.editor)return;
              send({kind:'noteInsertPassage',id:e.id,anchors:e.anchors,markdown:e.input.value,from:e.editor.selectionStart,to:e.editor.selectionEnd});
            },'引用阅读笔记');
            const done=button('完成',finish);done.className='note-done';e.footer.append(e.status,insert,done);e.card.append(header,e.input,e.content,e.summary,e.footer);
            e.card.addEventListener('mouseenter',()=>{if(!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('focusin',()=>{if(!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('click',event=>{if(event.target.closest('button,.note-editor,a,summary,select,#annotation-menu'))return;if(editing!==e.id)activate(e.id,true,true);});
            e.card.addEventListener('keydown',event=>{if(event.target===e.card&&(event.key==='Enter'||event.key===' ')){event.preventDefault();activate(e.id,true,true);}});
            body(e);layer.append(e.card);records.set(e.id,e);return e;
          };
          const showUndo=()=>{let b=document.getElementById('reader-note-undo');if(!b){b=button('笔记已删除 · 撤销',()=>{send({kind:'noteUndo'});b.remove();});b.id='reader-note-undo';document.body.append(b);}};
          const arrange=()=>{
            queued=false;const occupied=[],items=[...records.values()].sort((a,b)=>(a.id===active?-1:0)-(b.id===active?-1:0)||((document.getElementById('block-'+a.anchors[0].key)?.compareDocumentPosition(document.getElementById('block-'+b.anchors[0].key))||0)&Node.DOCUMENT_POSITION_FOLLOWING?-1:1));let chosen=null;
            for(const e of items){
              const isActive=e.id===active,isEditor=editing===e.id;
              e.card.classList.toggle('active',isActive);
              if(sidebar&&!isActive){e.slot=null;e.card.hidden=true;continue;}
              const previewHeight=width=>{
                e.card.hidden=false;e.card.style.width=width+'px';e.card.style.height='auto';e.card.style.maxHeight='none';
                return Math.max(e.slot?168:100,e.card.offsetHeight);
              };
              const height=isEditor?420:isActive?previewHeight:168;
              let position=layout.place(e.anchors,height,sidebar,occupied,!isActive,isActive&&!isEditor?e.slot:null);
              if(!position&&isEditor){position={left:Math.max(16,innerWidth-366),top:16,width:350,height:Math.min(420,innerHeight-32),side:'floating'};}
              if(!position){e.slot=null;e.previewBox=null;e.card.hidden=true;continue;}
              e.card.hidden=false;e.card.classList.toggle('compact',position.height<300);
              position.fixed=isEditor;
              const top=position.top+(isEditor?0:scrollY),box={left:position.left,top,right:position.left+position.width,bottom:top+position.height};
              // A hovered margin card expands from its own resting slot. Its target never
              // animates away from a pointer crossing over from the highlighted text.
              if(!isActive)e.slot={top,side:position.side};
              e.previewBox=isActive&&!isEditor?box:null;
              Object.assign(e.card.style,{position:isEditor?'fixed':'absolute',left:position.left+'px',top:top+'px',
                width:position.width+'px',height:position.height+'px',maxHeight:position.height+'px'});
              e.card.dataset.placement=position.side;
              occupied.push({...position,right:box.right,bottom:position.top+position.height});if(isActive)chosen=position;
            }
            const entry=records.get(active),opening=!!entry?.entrance;
            layout.decorate([...records.values()],entry,chosen,opening?false:reverse,opening);
            if(opening&&chosen){entry.entrance=false;emerge(entry,chosen);}
            if(entry?.needsFocus&&chosen){entry.needsFocus=false;entry.input.focus({preventScroll:true});}
            const crossing=pendingCrossing;pendingCrossing=null;
            if(crossing&&entry?.id===crossing.id&&!editing&&!layout.inBridge(entry.anchors,entry.previewBox,crossing.x,crossing.y))leave();
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
          function schedule(){if(!queued){queued=true;requestAnimationFrame(()=>{if(queued)arrange();});setTimeout(()=>{if(queued)arrange();},32);}}
          const begin=()=>{
            const anchors=normalize(selection.parts());if(!anchors.length)return;
            const existing=[...records.values()].find(e=>same(e.anchors,anchors));
            const e=existing||make({id:crypto.randomUUID().toUpperCase(),anchors,markdown:'',html:''});activate(e.id,true);
          };
          const hits=(x,y,precise=false)=>[...records.values()].filter(e=>layout.hit(e.anchors,x,y,precise));
          const setChoices=matches=>{for(const e of matches){e.choices.replaceChildren();e.choices.classList.toggle('note-hidden',matches.length<2);for(const [index,item] of matches.entries()){const o=document.createElement('option');o.value=item.id;o.textContent=(index+1)+' · '+(item.dimensionTitle||'笔记');o.selected=e.id===item.id;e.choices.append(o);}}};
          document.addEventListener('pointerdown',event=>{
            pointer={x:event.clientX,y:event.clientY};
            if(event.target.closest('.reader-note-card,#annotation-menu'))return;
            if(editing)finish();
          },true);
          root.addEventListener('click',event=>{
            if(!pointer||Math.hypot(event.clientX-pointer.x,event.clientY-pointer.y)>4||!getSelection().isCollapsed)return;
            const matches=hits(event.clientX,event.clientY,true);setChoices(matches);
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
          let pendingCrossing=null;
          document.addEventListener('pointermove',event=>{
            if(editing||event.buttons||event.pointerType==='touch')return;
            const x=event.clientX,y=event.clientY,card=event.target.closest?.('.reader-note-card');
            pendingCrossing=null;
            if(card){if(active!==card.dataset.noteId||!reverse)activate(card.dataset.noteId,false,true);return;}
            const matches=hits(x,y);
            if(matches.length){if(active!==matches[0].id){setChoices(matches);activate(matches[0].id);}return;}
            const e=records.get(active);
            if(e&&!e.previewBox&&queued){pendingCrossing={id:e.id,x,y};return;}
            if(!e||!layout.inBridge(e.anchors,e.previewBox,x,y))leave();
          });
          document.addEventListener('mouseleave',leave);
          document.addEventListener('keydown',event=>{if(event.key==='Escape'&&active)finish();});
          const resized=()=>{layout.invalidate();for(const e of records.values()){e.slot=null;e.previewBox=null;}schedule();};
          window.addEventListener('resize',resized);document.addEventListener('scroll',()=>layout.scrolled(),{passive:true});
          new ResizeObserver(resized).observe(root);document.fonts?.ready.then(resized);document.fonts?.addEventListener('loadingdone',resized);
          // The appendix follows the published reader; it never becomes a paper section or an annotation anchor.
          let appendix=null,appendixBody=null,appendixSource='';
          const summary=(id,source,html)=>{
            if(!id){appendix?.remove();appendix=null;appendixBody=null;return;}
            if(!appendix){
              appendix=document.createElement('article');appendix.id='reader-document-summary';appendix.setAttribute('aria-label','文末总结');
              const head=document.createElement('header'),title=document.createElement('strong');title.textContent='文末总结';
              head.append(title,button('编辑',()=>send({kind:'noteEditSummary',id:appendix.dataset.noteId}),'编辑文末总结'));
              appendixBody=document.createElement('div');appendix.append(head,appendixBody);root.after(appendix);
              PaperNoteEditor.bindPassages(appendix,passage=>send({kind:'notePreviewPassage',id:appendix.dataset.noteId,passage}));
            }
            appendix.dataset.noteId=id;appendixSource=source;
            if(html){appendixBody.innerHTML=html;appendixBody.style.whiteSpace='normal';}
            else{appendixBody.textContent=source;appendixBody.style.whiteSpace='pre-wrap';}
          };
          window.paperNotes={
            summary,
            begin,editing:()=>!!editing,preservingSelection:()=>!!editing,
            sidebar(open){if(sidebar!==open){sidebar=open;resized();}},
            sync(notes){
              let changed=false;const ids=new Set(notes.map(n=>n.id));
              for(const [id,e] of records)if(e.persisted&&!ids.has(id)&&editing!==id){e.editor?.destroy();e.card.remove();records.delete(id);changed=true;}
              for(const note of notes){let e=records.get(note.id);if(!e){e=make(note);changed=true;}e.persisted=true;
                if(editing!==e.id){if(e.markdown!==note.markdown){e.html='';changed=true;}e.markdown=note.markdown;e.anchors=note.anchors;e.html=note.html||e.html;body(e);}
              }if(changed)schedule();
            },
            preview(id,source,html){if(appendix?.dataset.noteId===id&&appendixSource===source){summary(id,source,html);return;}const e=records.get(id);if(!e||e.markdown!==source)return;e.html=html;e.content.style.whiteSpace='normal';body(e);e.editor?.preview(source,html);if(active===id&&!editing)schedule();},
            previewError(id){const e=records.get(id);if(e){e.content.textContent=e.markdown;e.status.textContent='预览失败，源码已保留';}},
            saved(status){lastStatus=status;for(const e of records.values())e.status.textContent=status;},
            insertPassage(id,source,from,to,markdown){return editing===id&&records.get(id)?.editor?.insertPassage(source,from,to,markdown);},
            open(id,edit){const e=records.get(id);if(!e)return;document.getElementById('block-'+e.anchors[0].key)?.scrollIntoView({block:'center'});activate(id,edit);},
            finish,layout:schedule
          };
        })();
        """#
}
