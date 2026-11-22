import Foundation

/// Ephemeral image presentation; original nodes and persisted reading geometry remain intact.
enum HTMLImagePreviewScript {
    static let source = #"""
        (()=>{
          const style=document.createElement('style');style.textContent=`
            #reader-image-preview{position:fixed;z-index:10000;inset:0;margin:0;padding:0;border:0;width:100vw;height:100dvh;max-width:none;max-height:none;background:transparent;overflow:hidden;color:#faf8f3;overscroll-behavior:contain;contain:layout style}
            #reader-image-preview .preview-backdrop{position:absolute;inset:0;background:rgba(23,21,19,.64);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);opacity:0;will-change:opacity;transform:translateZ(0)}
            #reader-image-preview .preview-image{position:absolute;margin:0;padding:0;border:0;max-width:none;max-height:none;object-fit:contain;background:white;transform-origin:0 0;will-change:transform;box-shadow:0 12px 48px #0004;cursor:zoom-out;user-select:none;-webkit-user-select:none}
            #reader-image-preview .preview-tools{position:absolute;z-index:1;top:max(16px,env(safe-area-inset-top));right:max(20px,env(safe-area-inset-right));display:flex;gap:10px;opacity:0}
            #reader-image-preview button{float:none;border:1px solid #ffffff35;border-radius:10px;background:#faf8f3;color:#544338;padding:9px 15px;font:500 14px/1.3 system-ui;cursor:pointer}
            #reader-image-preview .preview-title{position:absolute;top:max(23px,env(safe-area-inset-top));left:16px;max-width:24%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:white;font:600 15px/1.35 system-ui}
            #reader-image-preview .preview-viewport{position:absolute;inset:68px 12px 12px;overflow:auto;overscroll-behavior:contain;touch-action:pan-x pan-y;border-radius:4px}
            #reader-image-preview .preview-plane{display:grid;place-items:center;min-width:100%;width:max-content;min-height:100%}
            #reader-image-preview .preview-plane>.preview-image{position:static;display:block}
            #reader-image-preview[data-details] .preview-tools{right:max(12px,env(safe-area-inset-right));gap:6px}
            #reader-image-preview[data-details] button{min-height:44px;padding:6px 10px}
            #reader-image-preview[data-details]:not([data-zoomed]) .preview-image{cursor:zoom-in}
            @media(max-width:380px){#reader-image-preview .preview-title{max-width:18%;left:8px}#reader-image-preview[data-details] button{padding:6px}}
            @media(max-width:320px){#reader-image-preview .preview-title{display:none}}
            #reader-image-preview button:hover{background:#e9dfd0}#reader-image-preview button:focus-visible{outline:3px solid #e6b68e;outline-offset:3px}
          `;document.head.append(style);
          let active=null,gesture=null;
          const reduced=()=>matchMedia('(prefers-reduced-motion:reduce)').matches;
          const stop=s=>{for(const animation of s.animations)animation.cancel();s.animations=[];};
          const animate=(s,node,frames,duration)=>{
            const animation=node.animate(frames,{duration,easing:'cubic-bezier(.22,.75,.25,1)',fill:'both'});s.animations.push(animation);
            // WebKit may defer finished while its rendering clock is paused. Never gate dismissal on it alone.
            return new Promise(resolve=>{const timer=setTimeout(resolve,duration+60);animation.finished.then(()=>{clearTimeout(timer);resolve();},()=>{clearTimeout(timer);resolve();});});
          };
          const draw=(s,width,height)=>{
            s.large.style.width=width+'px';s.large.style.height=height+'px';
            const png=s.detail && s.source.currentSrc.startsWith('data:image/png;');
            const density=Math.min(devicePixelRatio||1,4096/Math.max(width,height),png?s.source.naturalWidth/width:Infinity);
            s.large.width=Math.max(1,Math.ceil(width*density));s.large.height=Math.max(1,Math.ceil(height*density));
            const context=s.large.getContext('2d');context.fillStyle='#fff';context.fillRect(0,0,s.large.width,s.large.height);context.drawImage(s.source,0,0,s.large.width,s.large.height);
          };
          const fittedBox=s=>{
            const ratio=s.source.naturalWidth/s.source.naturalHeight;
            const width=Math.max(1,Math.min(innerWidth-40,(innerHeight-112)*ratio));
            const height=width/ratio;
            return {left:(innerWidth-width)/2,top:72+(innerHeight-88-height)/2,width,height};
          };
          const fit=s=>{
            const box=fittedBox(s);s.box=box;s.large.style.left=box.left+'px';s.large.style.top=box.top+'px';
            draw(s,box.width,box.height);
          };
          const zoom=(s,enabled,point)=>{
            if(!s.detail||s.closing)return;
            stop(s);s.large.style.transform='none';s.shade.style.opacity='1';s.tools.style.opacity='1';
            s.zoomed=enabled;s.dialog.toggleAttribute('data-zoomed',enabled);s.viewport.hidden=!enabled;
            s.detail.setAttribute('aria-pressed',String(enabled));
            s.detail.textContent=enabled?'适合窗口':'放大细节';
            if(enabled){
              const width=Math.max(s.box.width*2,Math.min(s.source.naturalWidth,4096));
              const height=width*s.source.naturalHeight/s.source.naturalWidth;
              s.plane.append(s.large);draw(s,width,height);
              s.viewport.scrollLeft=point ? width*point.x-s.viewport.clientWidth/2 : 0;
              s.viewport.scrollTop=point ? height*point.y-s.viewport.clientHeight/2 : 0;
            }else{s.dialog.insertBefore(s.large,s.tools);fit(s);}
          };
          const fromRect=(r,b)=>'translate('+(r.left-b.left)+'px,'+(r.top-b.top)+'px) scale('+(r.width/b.width)+','+(r.height/b.height)+')';
          const dispose=s=>{
            if(active!==s)return;active=null;stop(s);s.events.abort();
            s.source.style.visibility=s.visibility;s.dialog.remove();
            if(s.focus?.isConnected)s.focus.focus({preventScroll:true});
          };
          const close=async(quote=false)=>{
            const s=active;if(!s||s.closing)return;s.closing=true;
            const current=getComputedStyle(s.large).transform,opacity=getComputedStyle(s.shade).opacity;
            stop(s);
            const r=s.source.getBoundingClientRect(),canReturn=s.source.isConnected&&r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight;
            if(!reduced()&&s.dialog.isConnected&&!s.zoomed){
              await Promise.all([
                animate(s,s.large,[{transform:current,opacity:1},{transform:canReturn?fromRect(r,s.box):current,opacity:canReturn?1:0}],170),
                animate(s,s.shade,[{opacity},{opacity:0}],170),
                animate(s,s.tools,[{opacity:getComputedStyle(s.tools).opacity},{opacity:0}],110)
              ]);
            }
            if(active!==s)return;dispose(s);
            if(quote&&s.source.isConnected)s.action(s.source);
          };
          const open=async (source,settings={})=>{
            if(!source.complete||!source.naturalWidth||!source.naturalHeight)return;
            if(active?.source===source)return;
            if(active)dispose(active);
            const started=performance.now();
            const dialog=document.createElement('div');dialog.id='reader-image-preview';dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label',settings.title||'图片预览');dialog.tabIndex=-1;
            const shade=document.createElement('div');shade.className='preview-backdrop';
            const large=document.createElement('canvas');large.className='preview-image';large.setAttribute('role','img');large.setAttribute('aria-label',settings.title||source.alt||'论文图片');large.imageSource=source;
            const tools=document.createElement('div');tools.className='preview-tools';
            const quote=document.createElement('button');quote.textContent=settings.actionLabel||'引用图片';quote.type='button';
            const dismiss=document.createElement('button');dismiss.textContent='关闭';dismiss.type='button';dismiss.setAttribute('aria-label','关闭放大图片');
            tools.append(quote,dismiss);dialog.append(shade,large,tools);
            const s={source,dialog,shade,large,tools,visibility:source.style.visibility,focus:settings.opener||document.activeElement,action:settings.onAction||(image=>window.paperSelection?.selectObject(image)),events:new AbortController(),animations:[],closing:false};active=s;
            if(settings.details){
              dialog.setAttribute('data-details','');
              if(settings.title){
                const title=document.createElement('span');title.className='preview-title';title.textContent=settings.title;
                dialog.append(title);
              }
              const detail=document.createElement('button');detail.type='button';detail.textContent='放大细节';
              detail.setAttribute('aria-pressed','false');tools.prepend(detail);
              const viewport=document.createElement('div');viewport.className='preview-viewport';viewport.hidden=true;
              const plane=document.createElement('div');plane.className='preview-plane';viewport.append(plane);
              dialog.insertBefore(viewport,tools);Object.assign(s,{detail,viewport,plane,zoomed:false});
            }
            // The source is already decoded. Present synchronously using its cached resource.
            const origin=source.getBoundingClientRect();if(origin.width<=0||origin.height<=0){dispose(s);return;}
            fit(s);dialog.dataset.state='open';source.style.visibility='hidden';document.body.append(dialog);
            const options={signal:s.events.signal};
            dismiss.addEventListener('click',()=>close(),options);quote.addEventListener('click',()=>close(true),options);
            s.detail?.addEventListener('click',()=>zoom(s,!s.zoomed),options);
            dialog.addEventListener('click',event=>{
              if(event.detail&&gesture?.moved)return;
              if(event.target===large&&s.detail){
                const rect=large.getBoundingClientRect();
                zoom(s,!s.zoomed,{x:(event.clientX-rect.left)/rect.width,y:(event.clientY-rect.top)/rect.height});
              }else if([shade,large,dialog,s.viewport,s.plane].includes(event.target))close();
            },options);
            dialog.addEventListener('pointermove',event=>event.stopPropagation(),options);
            for(const type of ['wheel','touchmove'])dialog.addEventListener(type,event=>{
              if(!s.zoomed||!s.viewport.contains(event.target))event.preventDefault();
              event.stopPropagation();
            },{...options,passive:false});
            window.addEventListener('resize',()=>{
              if(s.closing)return;
              stop(s);
              if(s.zoomed){
                const view=s.viewport.getBoundingClientRect(),image=s.large.getBoundingClientRect();
                const center={x:(view.left+view.width/2-image.left)/image.width,y:(view.top+view.height/2-image.top)/image.height};
                s.box=fittedBox(s);zoom(s,true,center);
              }else fit(s);
              s.large.style.transform='none';s.shade.style.opacity='1';s.tools.style.opacity='1';
            },options);
            let prepared=0;const setup=performance.now()-started;requestAnimationFrame(()=>{window.webkit?.messageHandlers?.reader?.postMessage({kind:'imagePreviewTiming',setup,prepared,frame:performance.now()-started});if(active===s&&!s.closing&&(!s.detail||!dialog.contains(document.activeElement)))dismiss.focus({preventScroll:true});});
            if(reduced()){s.shade.style.opacity='1';s.tools.style.opacity='1';return;}
            const opening=Promise.all([
              animate(s,large,[{transform:fromRect(origin,s.box)},{transform:'none'}],230),
              animate(s,shade,[{opacity:0},{opacity:1}],230),
              animate(s,tools,[{opacity:0},{opacity:1}],170)
            ]);prepared=performance.now()-started;await opening;
            if(active===s&&!s.closing){s.large.style.transform='none';s.shade.style.opacity='1';s.tools.style.opacity='1';stop(s);}
          };
          document.addEventListener('pointerdown',event=>{gesture={x:event.clientX,y:event.clientY,moved:false};},true);
          document.addEventListener('pointermove',event=>{if(gesture&&event.buttons&&Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>4)gesture.moved=true;},true);
          document.addEventListener('click',event=>{
            const image=event.target.closest?.('#reader img');if(!image||event.button!==0)return;
            if(event.detail&&gesture&&(gesture.moved||Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>4))return;
            event.preventDefault();event.stopImmediatePropagation();open(image);
          },true);
          document.addEventListener('keydown',event=>{
            if(!active)return;
            if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();close();}
            else if(event.key==='Tab'){event.preventDefault();const buttons=[...active.tools.querySelectorAll('button')],index=buttons.indexOf(document.activeElement);buttons[(index+(event.shiftKey?-1:1)+buttons.length)%buttons.length].focus({preventScroll:true});}
            else if(active.zoomed&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(event.key)){
              event.preventDefault();event.stopImmediatePropagation();
              const pane=active.viewport;
              if(event.key==='Home')pane.scrollTo(0,0);
              else if(event.key==='End')pane.scrollTo(pane.scrollWidth,pane.scrollHeight);
              else {
                const dx=event.key==='ArrowRight'?48:event.key==='ArrowLeft'?-48:0;
                const dy={ArrowDown:48,ArrowUp:-48,PageDown:pane.clientHeight*.85,PageUp:-pane.clientHeight*.85}[event.key]||0;
                pane.scrollBy(dx,dy);
              }
            }else if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(event.key)||(event.key===' '&&!active.tools.contains(document.activeElement)))event.preventDefault();
          },true);
          window.paperImagePreview={open,close};
        })();
        """#
}
