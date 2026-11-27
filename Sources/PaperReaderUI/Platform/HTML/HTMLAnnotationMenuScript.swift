import PaperReaderKit

/// The palette is shared by the source reader, PDF reflow and the native PDF selection host.
enum HTMLAnnotationMenuScript {
    static let colors =
        "{"
        + AnnotationColor.allCases.map {
            "'\($0.rawValue)':['\($0.label)','\($0.hex)']"
        }.joined(separator: ",") + "}"

    static let install = #"""
        function installAnnotationMenu(options) {
          const colors=\#(colors);
          const css=document.createElement('style');
          css.textContent=`#annotation-menu{position:fixed;z-index:1000;width:272px;max-width:calc(100vw - 16px);box-sizing:border-box;padding:10px;background:#faf8f3;color:#39352f;border:1px solid #ded8cc;border-radius:14px;box-shadow:0 6px 24px #332d2829;font:13px/1.4 system-ui;user-select:none;-webkit-user-select:none}#annotation-menu[hidden],#annotation-menu [hidden]{display:none!important}#annotation-menu button{font:inherit;color:inherit;border:0;cursor:pointer;background:transparent;border-radius:7px}#annotation-menu button:focus-visible{outline:2px solid #a34c33}#annotation-menu .palette{display:flex;gap:2px;margin-bottom:9px}#annotation-menu .swatch{flex:1;height:30px;padding:6px;display:grid;place-items:center}#annotation-menu .swatch span{display:block;width:18px;height:18px;background:var(--color);border:1px solid #0002;border-radius:4px}#annotation-menu button[aria-pressed=true]{background:#d9d1c2;box-shadow:inset 0 0 0 1px #a99a82}#annotation-menu .modes{display:flex;background:#eeeae2;padding:3px;border-radius:9px;margin-bottom:8px}#annotation-menu .modes button{flex:1;padding:6px}#annotation-menu .action{display:block;width:100%;text-align:left;padding:8px 10px;border-top:1px solid #e6e0d5;border-radius:0}#annotation-menu .action:hover:not(:disabled){background:#eee7dd;border-radius:6px}#annotation-menu button:disabled{opacity:.4;cursor:default}#annotation-menu .remove{color:#a34c33}#annotation-menu .note-hint{float:right;font-size:11px;opacity:.7}@media(prefers-color-scheme:dark){#annotation-menu{background:#302d28;color:#eee8dc;border-color:#51493f;box-shadow:0 6px 24px #0005}#annotation-menu .modes{background:#24221f}#annotation-menu button[aria-pressed=true]{background:#665744;box-shadow:inset 0 0 0 1px #ad9776}#annotation-menu .action{border-color:#51493f}#annotation-menu .action:hover:not(:disabled){background:#423a30}#annotation-menu .remove{color:#e8a086}#annotation-menu button:focus-visible{outline-color:#e8a086}}`;
          document.head.append(css);
          const menu=document.createElement('div');menu.id='annotation-menu';menu.hidden=true;menu.setAttribute('role','dialog');menu.setAttribute('aria-label','选文批注');
          menu.innerHTML='<div class="palette" role="group" aria-label="标注颜色"></div><div class="modes" role="group" aria-label="标注模式"><button type="button" data-mode="highlight">高亮</button><button type="button" data-mode="underline">下划线</button></div><button type="button" class="action bookmark">添加书签</button><button type="button" class="action add-note">添加笔记</button><button type="button" class="action remove" hidden>取消高光</button>';
          if (options.embedded) {menu.style.position='static';menu.style.width='100%';menu.style.maxWidth='none';}
          document.body.append(menu);
          let color='yellow',mode='highlight',dragging=false,timer=null,dismissed=false,holding=false;
          const refresh=()=>{
            const state=options.appearance(), uniform=!!state.color && !!state.style;
            if(uniform){color=state.color;mode=state.style;}
            for(const button of menu.querySelectorAll('[data-color]')){
              button.setAttribute('aria-pressed',String(button.dataset.color===color && (!state.covered||uniform)));button.disabled=!state.enabled;
            }
            for(const button of menu.querySelectorAll('[data-mode]')){
              button.setAttribute('aria-pressed',String(button.dataset.mode===mode && (!state.covered||uniform)));button.disabled=!state.enabled;
            }
            const remove=menu.querySelector('.remove');remove.hidden=!state.covered;
            remove.textContent=uniform && mode==='underline' ? '取消下划线' : '取消高光';
          };
          const position=()=>{
            if(options.embedded || menu.classList.contains('note-docked'))return;
            const rects=options.bounds();if(!rects.length){menu.hidden=true;return;}
            const rect=rects[rects.length-1],height=menu.offsetHeight,width=menu.offsetWidth;
            const x=Math.max(8,Math.min(innerWidth-width-8,(rect.left+rect.right-width)/2));
            let y=rect.bottom+10;if(y+height>innerHeight-8)y=rect.top-height-10;
            menu.style.left=x+'px';menu.style.top=Math.max(8,Math.min(innerHeight-height-8,y))+'px';
          };
          const show=()=>{
            if(options.editing?.()){menu.hidden=!menu.classList.contains('note-docked');return;}
            if(!options.embedded && (dragging||dismissed||!options.hasSelection())){menu.hidden=true;return;}
            refresh();menu.hidden=false;position();
          };
          for(const [key,[label,hex]] of Object.entries(colors)){
            const button=document.createElement('button');button.type='button';button.className='swatch';button.dataset.color=key;
            button.setAttribute('aria-label',label);button.title=label;button.style.setProperty('--color',hex);button.innerHTML='<span></span>';
            button.onclick=()=>{color=key;options.apply(color,mode,false);};menu.querySelector('.palette').append(button);
          }
          for(const button of menu.querySelectorAll('[data-mode]'))button.onclick=()=>{mode=button.dataset.mode;options.apply(color,mode,false);};
          menu.querySelector('.add-note').onclick=()=>options.addNote();
          menu.querySelector('.remove').onclick=()=>options.apply(color,mode,true);
          menu.querySelector('.bookmark').onclick=()=>{options.addBookmark();menu.querySelector('.bookmark').textContent='已添加书签';};
          const hide=()=>{holding=false;dismissed=true;menu.hidden=true;};
          // PDFKit supplies its own selection bounds and dismissal. Web readers preserve the native range during edits.
          if(!options.embedded){
            menu.addEventListener('pointerdown',event=>{holding=true;event.preventDefault();});
            menu.addEventListener('mousedown',event=>{holding=true;event.preventDefault();});
            menu.addEventListener('focusin',()=>{holding=true;});
            document.addEventListener('pointerdown',event=>{
              if(menu.contains(event.target)||event.target.closest?.('.reader-note-card'))return;
              holding=false;dragging=true;menu.hidden=true;dismissed=false;
            });
            const endDrag=()=>{dragging=false;clearTimeout(timer);timer=setTimeout(show,30);};
            document.addEventListener('pointerup',endDrag,true);
            document.addEventListener('pointercancel',endDrag,true);
            document.addEventListener('keydown',event=>{
              if(event.key==='Escape'){hide();}
              else if(event.key==='Tab' && !event.shiftKey && !menu.hidden && !menu.contains(document.activeElement)
                      && !menu.classList.contains('note-docked')) {
                menu.querySelector('[data-color][aria-pressed=true],.swatch')?.focus({preventScroll:true});event.preventDefault();
              }
            });
            document.addEventListener('scroll',()=>{if(!menu.hidden)position();},{capture:true,passive:true});
            window.addEventListener('resize',()=>{if(!menu.hidden)position();});
            window.addEventListener('blur',()=>{dragging=false;clearTimeout(timer);hide();});
          }
          return {
            selectionChanged(){dismissed=false;menu.querySelector('.bookmark').textContent='添加书签';clearTimeout(timer);timer=setTimeout(show,120);},
            refresh(){refresh();if(!menu.hidden)position();},
            preservingSelection:()=>holding, hide, show
          };
        }
        """#

    /// Both web views expose their verified offsets as intervals within a language-specific text run.
    static let appearance = #"""
          const overlap=(a,b)=>a.key===b.key && a.target===b.target && a.range[0]<b.range[1] && b.range[0]<a.range[1];
          function annotationAppearance(parts,marks) {
            const touched=marks.filter(m=>parts.some(p=>overlap(m,p)));
            const covered=parts.length>0 && parts.every(p=>{
              let end=p.range[0];
              for(const m of marks.filter(m=>overlap(m,p)).sort((a,b)=>a.range[0]-b.range[0])){if(m.range[0]>end)return false;end=Math.max(end,m.range[1]);}
              return end>=p.range[1];
            });
            const uniform=covered && touched.length>0 && touched.every(m=>m.color===touched[0].color && m.style===touched[0].style);
            return {enabled:!!parts.length,covered,color:uniform?touched[0].color:null,style:uniform?touched[0].style:null};
          };
        """#

    static let source = #"""
        (()=>{
          const selection=window.paperSelection;if(!selection)return;
          \#(install)
          \#(appearance)
          const send=value=>window.webkit.messageHandlers.reader.postMessage(value);
          const eligible=()=>selection.parts().map(p=>({...p,range:[p.highlightStart??p.start,p.highlightEnd??p.end]})).filter(p=>p.range[1]>p.range[0]);
          const marks=()=>selection.projectedMarks().flatMap(m=>m.parts.map(p=>({...p,key:m.key,color:m.color||'yellow',style:m.style||'highlight'})));
          const apply=(color,mode,remove)=>{
            const parts=eligible();if(!parts.length)return;
            const legacy=[];
            for(const m of selection.projectedMarks().filter(m=>!m.target)) {
              if(!m.parts.length && parts.some(p=>p.key===m.key)){send({kind:'annotationError'});return;}
              if(m.parts.some(p=>parts.some(s=>overlap({...p,key:m.key},s))))legacy.push({id:m.id,parts:m.parts});
            }
            send({kind:'annotationAction',color,style:mode,remove,legacy});
          };
          window.paperAnnotationMenu=installAnnotationMenu({
            appearance:()=>annotationAppearance(eligible(),marks()), apply,
            hasSelection:()=>selection.parts().length>0,bounds:()=>selection.selectionBounds(),
            editing:()=>window.paperNotes?.editing(), addNote:()=>window.paperNotes?.begin(),
            addBookmark:()=>send({kind:'selectionBookmark'})
          });
        })();
        """#
}
