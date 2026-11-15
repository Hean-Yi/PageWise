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
            const e=records.get(id);if(!e)return;active=id;reverse=backwards;
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
            const e={...note,persisted:false};e.card=document.createElement('article');e.card.className='reader-note-card';e.card.hidden=true;e.card.dataset.noteId=e.id;e.card.tabIndex=0;e.card.setAttribute('aria-label','阅读笔记');
            const header=document.createElement('header'),title=document.createElement('strong');title.textContent='笔记';header.append(title);
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
            e.footer=document.createElement('footer');e.footer.className='note-hidden';e.status=document.createElement('button');e.status.type='button';e.status.textContent=lastStatus;e.status.onclick=flush;
            const done=button('完成',finish);done.className='note-done';e.footer.append(e.status,done);e.card.append(header,e.input,e.content,e.summary,e.footer);
            e.card.addEventListener('mouseenter',()=>{if(!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('focusin',()=>{if(!editing&&(active!==e.id||!reverse))activate(e.id,false,true);});
            e.card.addEventListener('click',event=>{if(event.target.closest('button,.note-editor,a,summary,select,#annotation-menu'))return;if(editing!==e.id)activate(e.id,true,true);});
            e.card.addEventListener('keydown',event=>{if(event.target===e.card&&(event.key==='Enter'||event.key===' ')){event.preventDefault();activate(e.id,true,true);}});
            body(e);layer.append(e.card);records.set(e.id,e);return e;
          };
          const showUndo=()=>{let b=document.getElementById('reader-note-undo');if(!b){b=button('笔记已删除 · 撤销',()=>{send({kind:'noteUndo'});b.remove();});b.id='reader-note-undo';document.body.append(b);}};
          const arrange=()=>{
            queued=false;const occupied=[],items=[...records.values()].sort((a,b)=>(a.id===active?-1:0)-(b.id===active?-1:0)||((document.getElementById('block-'+a.anchors[0].key)?.compareDocumentPosition(document.getElementById('block-'+b.anchors[0].key))||0)&Node.DOCUMENT_POSITION_FOLLOWING?-1:1));let chosen=null;
            for(const e of items){const isActive=e.id===active,wasActive=e.card.classList.contains('active'),oldRect=!e.card.hidden?e.card.getBoundingClientRect():null;e.card.classList.toggle('active',isActive);
              if(sidebar&&!isActive){e.card.hidden=true;continue;}
              const height=isActive?(editing===e.id?420:Math.min(420,Math.max(100,e.content.scrollHeight+52))):168;
              let position=layout.place(e.anchors,height,sidebar,occupied,!isActive);
              if(!position&&editing===e.id){position={left:Math.max(16,innerWidth-366),top:16,width:350,height:Math.min(420,innerHeight-32),side:'floating'};}
              if(!position||(!isActive&&position.side==='floating')){e.card.hidden=true;continue;}
              e.card.hidden=false;e.card.classList.toggle('compact',position.height<300);position.fixed=editing===e.id;e.card.style.position=position.fixed?'fixed':'absolute';e.card.style.left=position.left+'px';e.card.style.top=(position.top+(position.fixed?0:scrollY))+'px';e.card.style.width=position.width+'px';e.card.style.maxHeight=Math.max(oldRect?.height||0,position.height)+'px';e.card.style.height=position.height+'px';e.card.dataset.placement=position.side;
              if(e.entrance){e.moveAnimation?.cancel();e.card.style.maxHeight=position.height+'px';}
              else if(oldRect&&wasActive!==isActive&&!matchMedia('(prefers-reduced-motion:reduce)').matches){const next=e.card.getBoundingClientRect(),dy=isActive?-2:0;e.moveAnimation?.cancel();e.moveAnimation=e.card.animate([{height:oldRect.height+'px',transform:'translate('+(oldRect.left-next.left)+'px,'+(oldRect.top-next.top+dy)+'px)'},{height:position.height+'px',transform:'translate(0,'+dy+'px)'}],{duration:isActive?180:160,easing:'cubic-bezier(.2,.7,.2,1)'});e.moveAnimation.onfinish=()=>{e.card.style.maxHeight=position.height+'px';};}else if(e.moveAnimation?.playState!=='running')e.card.style.maxHeight=position.height+'px';
              occupied.push({...position,right:position.left+position.width,bottom:position.top+position.height});if(isActive)chosen=position;
            }
            const entry=records.get(active),opening=!!entry?.entrance;
            layout.decorate([...records.values()],entry,chosen,opening?false:reverse,opening);
            if(opening&&chosen){entry.entrance=false;emerge(entry,chosen);}
            if(entry?.needsFocus&&chosen){entry.needsFocus=false;entry.input.focus();}
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
          const setChoices=matches=>{for(const e of matches){e.choices.replaceChildren();e.choices.classList.toggle('note-hidden',matches.length<2);for(const item of matches){const o=document.createElement('option');o.value=item.id;o.textContent=(item.markdown||'空白笔记').slice(0,24);o.selected=e.id===item.id;e.choices.append(o);}}};
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
          let lastPointer=null;
          document.addEventListener('pointermove',event=>{
            if(editing||event.buttons)return;
            const card=event.target.closest?.('.reader-note-card');
            if(card){if(active!==card.dataset.noteId||!reverse)activate(card.dataset.noteId,false,true);lastPointer={x:event.clientX,y:event.clientY};return;}
            const matches=hits(event.clientX,event.clientY);
            if(matches.length){if(active!==matches[0].id){setChoices(matches);activate(matches[0].id);}lastPointer={x:event.clientX,y:event.clientY};return;}
            const e=records.get(active);
            if(!e||!layout.inBridge(e.anchors,e.card,event.clientX,event.clientY,lastPointer))leave();
            lastPointer={x:event.clientX,y:event.clientY};
          });
          document.addEventListener('mouseleave',leave);
          document.addEventListener('keydown',event=>{if(event.key==='Escape'&&active)finish();});
          window.addEventListener('resize',schedule);document.addEventListener('scroll',()=>layout.scrolled(),{passive:true});new ResizeObserver(schedule).observe(root);document.fonts?.ready.then(schedule);
          window.paperNotes={
            begin,editing:()=>!!editing,preservingSelection:()=>!!editing,
            sidebar(open){sidebar=open;schedule();},
            sync(notes){
              let changed=false;const ids=new Set(notes.map(n=>n.id));
              for(const [id,e] of records)if(e.persisted&&!ids.has(id)&&editing!==id){e.editor?.destroy();e.card.remove();records.delete(id);changed=true;}
              for(const note of notes){let e=records.get(note.id);if(!e){e=make(note);changed=true;}e.persisted=true;
                if(editing!==e.id){if(e.markdown!==note.markdown){e.html='';changed=true;}e.markdown=note.markdown;e.anchors=note.anchors;e.html=note.html||e.html;body(e);}
              }if(changed)schedule();
            },
            preview(id,source,html){const e=records.get(id);if(!e||e.markdown!==source)return;e.html=html;e.content.style.whiteSpace='normal';body(e);e.editor?.preview(source,html);if(active===id&&!editing)schedule();},
            previewError(id){const e=records.get(id);if(e){e.content.textContent=e.markdown;e.status.textContent='预览失败，源码已保留';}},
            saved(status){lastStatus=status;for(const e of records.values())e.status.textContent=status;},
            open(id,edit){const e=records.get(id);if(!e)return;document.getElementById('block-'+e.anchors[0].key)?.scrollIntoView({block:'center'});activate(id,edit);},
            finish,layout:schedule
          };
        })();
        """#
}
