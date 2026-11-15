import Foundation

enum HTMLNotesScript {
    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection,layout=window.paperNoteLayout,menu=document.getElementById('annotation-menu');
          const layer=document.createElement('div');layer.id='reader-note-layer';document.body.append(layer);
          const records=new Map();let active=null,editing=null,sidebar=true,reverse=false,hoverTimer=null,leaveTimer=null,queued=false,pointer=null,lastStatus='已保存';
          const send=v=>window.webkit.messageHandlers.reader.postMessage({...v,paperID:document.body.dataset.paperId});
          const normalize=a=>a.map(p=>({key:p.key,target:p.target,text:p.text,start:p.start??p.range?.[0],end:p.end??p.range?.[1]}));
          const same=(a,b)=>JSON.stringify(normalize(a))===JSON.stringify(normalize(b));
          const body=e=>{if(e.html)e.content.innerHTML=e.html;else {e.content.textContent=e.markdown||'点击添加笔记';e.content.style.whiteSpace='pre-wrap';}};
          const undock=()=>{if(menu.classList.contains('note-docked')){document.body.append(menu);menu.classList.remove('note-docked');menu.hidden=true;}};
          const flush=()=>send({kind:'noteFlush'});
          const store=e=>{e.markdown=e.input.value;e.html='';e.previewLabel.textContent='实时预览 · 更新中';e.status.textContent='保存中…';send({kind:'noteChange',id:e.id,anchors:e.anchors,markdown:e.markdown});};
          const finish=()=>{
            clearTimeout(hoverTimer);clearTimeout(leaveTimer);
            const e=records.get(editing);if(e){if(e.input.value!==e.markdown)store(e);e.card.classList.remove('editing-live');e.previewLabel.classList.add('note-hidden');e.input.classList.add('note-hidden');e.footer.classList.add('note-hidden');e.content.classList.remove('note-hidden');e.tabs.classList.add('note-hidden');body(e);flush();}
            if(e?.card.contains(document.activeElement))document.activeElement.blur();
            editing=null;active=null;undock();selection.clear();
            if(e&&!e.markdown.trim()&&!e.persisted){e.card.remove();records.delete(e.id);}schedule();
          };
          const activate=(id,edit=false,backwards=false)=>{
            if(editing&&editing!==id){if(!edit)return;finish();}
            const e=records.get(id);if(!e)return;clearTimeout(hoverTimer);clearTimeout(leaveTimer);active=id;reverse=backwards;
            if(edit){
              editing=id;e.tabs.classList.remove('note-hidden');e.footer.classList.remove('note-hidden');e.card.classList.add('editing-live');e.input.classList.remove('note-hidden');e.content.classList.remove('note-hidden');e.previewLabel.classList.remove('note-hidden');
              selection.restore(e.anchors);menu.classList.add('note-docked');e.card.prepend(menu);menu.hidden=false;window.paperAnnotationMenu.refresh();
              e.input.value=e.markdown;e.input.focus({preventScroll:true});
            }
            schedule();
          };
          const laterLeave=()=>{clearTimeout(leaveTimer);leaveTimer=setTimeout(()=>{if(!editing){active=null;schedule();}},180);};
          const button=(text,handler,label=text)=>{const b=document.createElement('button');b.type='button';b.textContent=text;b.setAttribute('aria-label',label);b.onclick=event=>{event.stopPropagation();handler();};return b;};
          const make=note=>{
            const e={...note,persisted:false};e.card=document.createElement('article');e.card.className='reader-note-card';e.card.dataset.noteId=e.id;e.card.tabIndex=0;e.card.setAttribute('aria-label','阅读笔记');
            const header=document.createElement('header'),title=document.createElement('strong');title.textContent='笔记';header.append(title);
            e.choices=document.createElement('select');e.choices.setAttribute('aria-label','重叠笔记');e.choices.className='note-hidden';e.choices.onchange=()=>activate(e.choices.value,!!editing);header.append(e.choices);
            e.tabs=document.createElement('span');e.tabs.className='note-hidden';
            e.tabs.append(button('编辑',()=>{e.card.classList.add('editing-live');e.content.classList.remove('note-hidden');e.previewLabel.classList.remove('note-hidden');e.input.classList.remove('note-hidden');e.input.focus({preventScroll:true});}),button('预览',()=>{e.card.classList.remove('editing-live');e.previewLabel.classList.add('note-hidden');e.input.classList.add('note-hidden');e.content.classList.remove('note-hidden');body(e);}));header.append(e.tabs);header.append(button('原文',()=>{document.getElementById('block-'+e.anchors[0].key)?.scrollIntoView({block:'center'});schedule();},'定位笔记原文'));
            const more=document.createElement('details'),summary=document.createElement('summary');summary.textContent='···';summary.setAttribute('aria-label','笔记更多操作');more.append(summary);
            more.append(button('删除笔记',()=>{const id=e.id;finish();send({kind:'noteDelete',id});e.card.remove();records.delete(id);showUndo();schedule();}));header.append(more);
            e.input=document.createElement('textarea');e.input.className='note-hidden';e.input.setAttribute('aria-label','笔记 Markdown 编辑器');e.input.placeholder='写下想法，支持 Markdown、$行内公式$ 和 $$独立公式$$';e.input.spellcheck=false;
            e.input.oninput=()=>{store(e);};
            e.input.onkeydown=event=>{if((event.metaKey||event.ctrlKey)&&event.key==='Enter'){event.preventDefault();finish();}if(event.key==='Escape'){event.preventDefault();event.stopPropagation();finish();}};
            e.previewLabel=document.createElement('div');e.previewLabel.className='note-live-label note-hidden';e.previewLabel.textContent='实时预览';
            e.content=document.createElement('div');e.content.className='note-content';e.content.setAttribute('aria-label','笔记预览');
            e.footer=document.createElement('footer');e.footer.className='note-hidden';e.status=document.createElement('button');e.status.type='button';e.status.textContent=lastStatus;e.status.onclick=flush;
            const done=button('完成',finish);done.className='note-done';e.footer.append(e.status,done);e.card.append(header,e.input,e.previewLabel,e.content,e.footer);
            e.card.addEventListener('mouseenter',()=>{clearTimeout(leaveTimer);if(!editing){clearTimeout(hoverTimer);hoverTimer=setTimeout(()=>activate(e.id,false,true),150);}});
            e.card.addEventListener('mouseleave',laterLeave);
            e.card.addEventListener('focusin',()=>{clearTimeout(leaveTimer);if(!editing)activate(e.id,false,true);});
            e.card.addEventListener('click',event=>{if(event.target.closest('button,textarea,a,summary,select,#annotation-menu'))return;if(editing!==e.id)activate(e.id,true,true);});
            e.card.addEventListener('keydown',event=>{if(event.target===e.card&&(event.key==='Enter'||event.key===' ')){event.preventDefault();activate(e.id,true,true);}});
            body(e);layer.append(e.card);records.set(e.id,e);return e;
          };
          const showUndo=()=>{let b=document.getElementById('reader-note-undo');if(!b){b=button('笔记已删除 · 撤销',()=>{send({kind:'noteUndo'});b.remove();});b.id='reader-note-undo';document.body.append(b);}};
          const arrange=()=>{
            queued=false;const occupied=[],items=[...records.values()].sort((a,b)=>(a.id===active?-1:0)-(b.id===active?-1:0)||((document.getElementById('block-'+a.anchors[0].key)?.compareDocumentPosition(document.getElementById('block-'+b.anchors[0].key))||0)&Node.DOCUMENT_POSITION_FOLLOWING?-1:1));let chosen=null;
            for(const e of items){const isActive=e.id===active,wasActive=e.card.classList.contains('active'),oldRect=!e.card.hidden?e.card.getBoundingClientRect():null;e.card.classList.toggle('active',isActive);
              if(sidebar&&!isActive){e.card.hidden=true;continue;}
              const height=isActive?(editing===e.id?420:Math.min(420,Math.max(100,e.content.scrollHeight+52))):112;
              let position=layout.place(e.anchors,height,sidebar,occupied,!isActive);
              if(!position&&editing===e.id){position={left:Math.max(16,innerWidth-366),top:16,width:350,height:Math.min(420,innerHeight-32),side:'floating'};}
              if(!position||(!isActive&&position.side==='floating')){e.card.hidden=true;continue;}
              e.card.hidden=false;e.card.classList.toggle('compact',position.height<300);position.fixed=editing===e.id;e.card.style.position=position.fixed?'fixed':'absolute';e.card.style.left=position.left+'px';e.card.style.top=(position.top+(position.fixed?0:scrollY))+'px';e.card.style.width=position.width+'px';e.card.style.maxHeight=position.height+'px';e.card.style.height=isActive?position.height+'px':'';e.card.dataset.placement=position.side;
              if(oldRect&&wasActive!==isActive&&!matchMedia('(prefers-reduced-motion:reduce)').matches){const next=e.card.getBoundingClientRect(),dy=isActive?-2:0;e.moveAnimation?.cancel();e.moveAnimation=e.card.animate([{transform:'translate('+(oldRect.left-next.left)+'px,'+(oldRect.top-next.top+dy)+'px)'},{transform:'translate(0,'+dy+'px)'}],{duration:200,easing:'cubic-bezier(.2,.7,.2,1)'});}
              occupied.push({...position,right:position.left+position.width,bottom:position.top+position.height});if(isActive)chosen=position;
            }
            layout.decorate([...records.values()],records.get(active),chosen,reverse);
          };
          function schedule(){if(!queued){queued=true;requestAnimationFrame(()=>{if(queued)arrange();});setTimeout(()=>{if(queued)arrange();},32);}}
          const begin=()=>{
            const anchors=normalize(selection.parts());if(!anchors.length)return;
            const existing=[...records.values()].find(e=>same(e.anchors,anchors));
            const e=existing||make({id:crypto.randomUUID().toUpperCase(),anchors,markdown:'',html:''});activate(e.id,true);
          };
          const hits=(x,y)=>[...records.values()].filter(e=>layout.hit(e.anchors,x,y));
          const setChoices=matches=>{for(const e of matches){e.choices.replaceChildren();e.choices.classList.toggle('note-hidden',matches.length<2);for(const item of matches){const o=document.createElement('option');o.value=item.id;o.textContent=(item.markdown||'空白笔记').slice(0,24);o.selected=e.id===item.id;e.choices.append(o);}}};
          document.addEventListener('pointerdown',event=>{
            pointer={x:event.clientX,y:event.clientY};
            if(event.target.closest('.reader-note-card,#annotation-menu'))return;
            if(editing)finish();
          },true);
          root.addEventListener('click',event=>{
            if(!pointer||Math.hypot(event.clientX-pointer.x,event.clientY-pointer.y)>4||!getSelection().isCollapsed)return;
            const matches=hits(event.clientX,event.clientY);setChoices(matches);
            if(matches.length){event.preventDefault();event.stopImmediatePropagation();activate(matches[0].id,true);return;}
            for(const mark of selection.projectedMarks()){
              const anchors=normalize(mark.parts.map(p=>({...p,key:mark.key})));
              if(!layout.hit(anchors,event.clientX,event.clientY))continue;
              event.preventDefault();event.stopImmediatePropagation();
              const e=make({id:crypto.randomUUID().toUpperCase(),anchors,markdown:'',html:''});activate(e.id,true);return;
            }
          },true);
          root.addEventListener('pointermove',event=>{
            if(editing||event.buttons)return;
            const matches=hits(event.clientX,event.clientY);setChoices(matches);
            if(matches.length){clearTimeout(leaveTimer);if(active!==matches[0].id){clearTimeout(hoverTimer);hoverTimer=setTimeout(()=>activate(matches[0].id),150);}}
            else {clearTimeout(hoverTimer);laterLeave();}
          });
          root.addEventListener('pointerleave',laterLeave);
          document.addEventListener('keydown',event=>{if(event.key==='Escape'&&active)finish();});
          window.addEventListener('resize',schedule);document.addEventListener('scroll',()=>layout.scrolled(),{passive:true});new ResizeObserver(schedule).observe(root);document.fonts?.ready.then(schedule);
          window.paperNotes={
            begin,editing:()=>!!editing,preservingSelection:()=>!!editing,
            sidebar(open){sidebar=open;schedule();},
            sync(notes){
              let changed=false;const ids=new Set(notes.map(n=>n.id));
              for(const [id,e] of records)if(e.persisted&&!ids.has(id)&&editing!==id){e.card.remove();records.delete(id);changed=true;}
              for(const note of notes){let e=records.get(note.id);if(!e){e=make(note);changed=true;}e.persisted=true;
                if(editing!==e.id){if(e.markdown!==note.markdown){e.html='';changed=true;}e.markdown=note.markdown;e.anchors=note.anchors;e.html=note.html||e.html;body(e);}
              }if(changed)schedule();
            },
            preview(id,source,html){const e=records.get(id);if(!e||e.markdown!==source)return;e.html=html;e.content.style.whiteSpace='normal';e.previewLabel.textContent='实时预览';body(e);if(active===id&&!editing)schedule();},
            previewError(id){const e=records.get(id);if(e){e.content.textContent=e.markdown;e.status.textContent='预览失败，源码已保留';}},
            saved(status){lastStatus=status;for(const e of records.values())e.status.textContent=status;},
            open(id,edit){const e=records.get(id);if(!e)return;document.getElementById('block-'+e.anchors[0].key)?.scrollIntoView({block:'center'});activate(id,edit);},
            finish,layout:schedule
          };
        })();
        """#
}
